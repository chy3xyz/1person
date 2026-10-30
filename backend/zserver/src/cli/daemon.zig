//! 1p daemon: local agent worker loop (M2+).
//!
//! Flow: register -> WebSocket connect -> periodic HTTP heartbeat +
//! claim polling with a WS frame poll (task_available + heartbeat_ack).
//! Reconnects on socket loss. Claimed tasks are executed per type (M4):
//! models / local_skills / update / local_skill_import, with results
//! reported to the module endpoints.
//!
//! Single-threaded: the WS is read with per-read timeouts inside the
//! main loop, so no reader thread / mutex is needed.

const std = @import("std");
const api = @import("api.zig");
const agent_exec = @import("agent_exec.zig");
const config_store = @import("config_store.zig");
const out = @import("out.zig");
const ws = @import("ws.zig");
const build_options = @import("build_options");

pub const DaemonOptions = struct {
    runtime_id: []const u8,
    workspace_id: ?[]const u8 = null,
    token: ?[]const u8 = null,
    path: []const u8,
    claim_interval_ms: u64 = 15000,
    heartbeat_interval_ms: u64 = 30000,
    /// The daemon's own environment — the base the agent CLI's overrides
    /// are applied to.
    environ_map: ?*const std.process.Environ.Map = null,
};

var g_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Where the daemon keeps the per-task working directories.
///
/// Set once at startup. The daemon is single-threaded, so a plain
/// variable is enough — and it keeps the working-directory plumbing out
/// of every call signature.
var g_work_root: []const u8 = "";

/// Cadence of the daemon's WebSocket keepalive frame. Must stay well
/// below the server's socket read timeout (30s) so the push channel is
/// not torn down and re-established on every timeout.
const daemon_ws_keepalive_ms: u64 = 10_000;

/// Cadence for retrying a server call that failed because the server was
/// unreachable. Short enough that the daemon picks its work back up
/// promptly once the server is back, long enough not to hammer a dead
/// socket.
const daemon_server_retry_ms: u64 = 5_000;

/// True for failures that mean "the server could not be reached, or did
/// not answer with JSON" — transient conditions a long-running daemon
/// has to survive by retrying instead of exiting. Everything else (an
/// out-of-memory, for instance) stays fatal and propagates.
fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.RequestFailed, error.InvalidJson => true,
        else => false,
    };
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    g_shutdown.store(true, .monotonic);
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: DaemonOptions) !void {
    var cfg = try config_store.load(allocator, io, opts.path);
    defer cfg.deinit();

    // The agent runs in a directory of its own, per task. See
    // `ensureTaskWorkDir`.
    {
        const base = std.fs.path.dirname(opts.path) orelse ".";
        const root = try std.fs.path.join(allocator, &.{ base, "work" });
        defer allocator.free(root);
        g_work_root = root;
    }

    if (cfg.server_url.len == 0) {
        out.printErr("no server_url configured — run \"1p login\" first (config: {s})\n", .{opts.path});
        return error.NotConfigured;
    }

    var token_buf: []const u8 = "";
    if (opts.token) |t| {
        token_buf = t;
    } else if (opts.workspace_id) |ws_id| {
        token_buf = cfg.daemon_tokens.get(ws_id) orelse {
            out.printErr("no daemon token for workspace {s} — run \"1p pair --workspace_id {s}\"\n", .{ ws_id, ws_id });
            return error.NoToken;
        };
    } else {
        var it = cfg.daemon_tokens.valueIterator();
        token_buf = if (it.next()) |v| v.* else {
            out.printErr("no daemon token stored — run \"1p pair\" first\n", .{});
            return error.NoToken;
        };
    }
    if (token_buf.len == 0) return error.NoToken;

    var client = try api.Client.init(allocator, cfg.server_url);
    defer client.deinit();

    // 1. signal handling for clean shutdown.
    //
    // Installed before the registration: registration retries while the
    // server is unreachable, and a daemon that is waiting for a server
    // that never comes up still has to be stoppable.
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // 2. register
    //
    // `cli_version` is the version of the 1p CLI this daemon runs. The
    // server stores it on the runtime row's `metadata.cli_version`, and
    // the quick-create gate reads it from there to decide whether this
    // daemon may serve an agent-create task.
    //
    // `provider` is the local agent CLI this machine can actually run.
    // Reporting it is what lets the server hand real work to this daemon:
    // without a provider there is nothing that could execute a task.
    const provider = agent_exec.detectProvider(allocator, io);
    // A daemon that found no agent CLI cannot execute anything, so it
    // advertises no capabilities — and the server then never hands it a
    // task it would only fail.
    const capabilities: []const []const u8 = if (provider != null)
        &[_][]const u8{"agent_tasks"}
    else
        &[_][]const u8{};
    const reg_body = try std.json.Stringify.valueAlloc(allocator, .{
        .runtime_id = opts.runtime_id,
        .cli_version = build_options.version,
        .provider = if (provider) |p| p.name() else "auto",
        .capabilities = capabilities,
    }, .{});
    defer allocator.free(reg_body);
    try registerDaemon(allocator, io, &client, token_buf, reg_body, opts.runtime_id);

    // 3. main loop: WS poll + heartbeat + claim
    const host_port = try parseHostPort(allocator, cfg.server_url);
    defer allocator.free(host_port.host);
    const ws_path = try std.fmt.allocPrint(allocator, "/api/daemon/ws?runtime_ids={s}", .{opts.runtime_id});
    defer allocator.free(ws_path);

    var ws_client: ?*ws.Client = null;
    var backoff_ms: u64 = 1000;
    var heartbeat_at: i64 = 0;
    var claim_at: i64 = nowMillis(io) + 3000;
    // The server bounds how long it waits for the next frame (30s), so
    // the socket needs traffic well inside that window. The HTTP
    // heartbeat runs on the `heartbeat_interval_ms` cadence (30s by
    // default), which is exactly the server's read timeout — the frame
    // always arrived a moment too late and the connection was dropped
    // and re-established every 30 seconds. The WS keepalive runs on its
    // own, shorter cadence.
    var ws_keepalive_at: i64 = 0;

    defer {
        if (ws_client) |c| {
            c.sendClose();
            c.deinit();
            allocator.destroy(c);
        }
    }

    while (!g_shutdown.load(.monotonic)) {
        const now = nowMillis(io);

        // Ensure WS connection
        if (ws_client == null) {
            const c = allocator.create(ws.Client) catch null;
            if (c) |client_ptr| {
                client_ptr.* = ws.Client.connect(allocator, io, host_port.host, host_port.port, ws_path, token_buf) catch |err| {
                    out.printErr("ws connect failed ({s}); retry in {d}ms\n", .{ @errorName(err), backoff_ms });
                    allocator.destroy(client_ptr);
                    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
                    backoff_ms = @min(backoff_ms * 2, 30000);
                    continue;
                };
                ws_client = client_ptr;
                backoff_ms = 1000;
                out.printOut("daemon websocket connected\n", .{});
            }
        }

        // Poll WS frames (150ms window; null = nothing arrived)
        if (ws_client) |c| {
            var frame_buf: [65536]u8 = undefined;
            const frame = c.readFrameTimeout(&frame_buf, 150) catch |err| {
                out.printErr("ws read error ({s}); reconnecting\n", .{@errorName(err)});
                c.deinit();
                allocator.destroy(c);
                ws_client = null;
                continue;
            };
            if (frame) |f| {
                switch (f.opcode) {
                    .ping => c.sendPong(f.payload) catch {},
                    .pong => {},
                    .close => {
                        out.printOut("websocket closed by server; reconnecting\n", .{});
                        c.deinit();
                        allocator.destroy(c);
                        ws_client = null;
                        continue;
                    },
                    .text, .binary => {
                        const text = f.payload;
                        if (std.mem.indexOf(u8, text, "daemon:task_available") != null) {
                            out.printOut("task_available push -> claiming now\n", .{});
                            claim_at = nowMillis(io);
                        } else if (std.mem.indexOf(u8, text, "daemon:heartbeat_ack") != null) {
                            // liveness ack, nothing to do
                        } else {
                            out.printOut("ws frame: {s}\n", .{text});
                        }
                    },
                    else => {},
                }
            }
        }

        // Claim poll. A server that went away must not take the daemon
        // with it: the transport failure is reported as "unreachable"
        // and retried on a short cadence, so the daemon resumes
        // claiming as soon as the server is back.
        if (now >= claim_at) {
            const server_up = try claimPoll(allocator, io, &client, token_buf, opts.runtime_id, opts.environ_map);
            claim_at = nowMillis(io) + @as(i64, @intCast(if (server_up) opts.claim_interval_ms else daemon_server_retry_ms));
        }

        // WS keepalive: a text frame well inside the server's read
        // timeout, so the push channel stays open instead of being torn
        // down and re-established every 30 seconds.
        if (now >= ws_keepalive_at) {
            ws_keepalive_at = nowMillis(io) + @as(i64, @intCast(daemon_ws_keepalive_ms));
            if (ws_client) |c| {
                c.sendText("{\"type\":\"daemon:heartbeat\"}") catch {};
            }
        }

        // Heartbeat (HTTP)
        if (now >= heartbeat_at) {
            heartbeat_at = nowMillis(io) + @as(i64, @intCast(opts.heartbeat_interval_ms));
            var hb = client.postJson(allocator, "/api/daemon/heartbeat", "", token_buf) catch |err| {
                out.printErr("heartbeat failed: {s}\n", .{@errorName(err)});
                continue;
            };
            defer hb.deinit();
        }

        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    // Deregister on shutdown
    var dr = client.postJson(allocator, "/api/daemon/deregister", "", token_buf) catch null;
    if (dr) |*r| r.deinit();
    out.printOut("daemon stopped\n", .{});
}

/// Register with the server, retrying while it is unreachable.
///
/// A daemon is routinely started before the server is up — and it has to
/// outlive a server restart — so a transport failure here must not take
/// the process down: the daemon waits and tries again. A rejection (the
/// server answered and refused the request) is fatal, because retrying
/// a genuinely bad request would loop forever.
fn registerDaemon(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *api.Client,
    token: []const u8,
    body: []const u8,
    runtime_id: []const u8,
) !void {
    var backoff_ms: u64 = 1000;
    while (true) {
        if (g_shutdown.load(.monotonic)) return error.ShutdownRequested;

        var resp = client.postJson(allocator, "/api/daemon/register", body, token) catch |err| {
            if (!isTransient(err)) return err;
            out.printErr("register failed ({s}); retrying in {d}ms\n", .{ @errorName(err), backoff_ms });
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(backoff_ms)), .awake) catch {};
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer resp.deinit();

        if (!resp.ok()) {
            out.printErr("register failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
            return error.RegisterFailed;
        }
        const daemon_id = resp.getString("daemon_id") orelse runtime_id;
        out.printOut("daemon registered: daemon_id={s} runtime_id={s}\n", .{ daemon_id, runtime_id });
        return;
    }
}

/// POST /api/daemon/runtimes/{rid}/tasks/claim; if a task is returned,
/// run the M4 executor (start -> per-type execution -> result report ->
/// complete/fail).
///
/// Returns false when the server could not be reached, so the caller can
/// retry sooner than the normal claim interval instead of waiting out a
/// full cycle for a server that is not there.
fn claimPoll(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8, base_env: ?*const std.process.Environ.Map) !bool {
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/tasks/claim", .{runtime_id});
    defer allocator.free(path);
    var resp = client.postJson(allocator, path, "", token) catch |err| {
        if (!isTransient(err)) return err;
        out.printErr("claim skipped ({s}); server unreachable, retrying\n", .{@errorName(err)});
        return false;
    };
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("claim failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return true;
    }
    if (resp.parsed.value != .object) return true;
    const task = resp.parsed.value.object.get("task") orelse return true;
    if (task != .object) return true;

    // Two kinds of work share this endpoint: agent tasks (a chat reply, an
    // issue the agent was pointed at) and the runtime's own maintenance
    // tasks. The `kind` field says which one this is.
    const kind = jsonStr(task, "kind") orelse "maintenance";
    if (std.mem.eql(u8, kind, "agent")) {
        try executeAgentTask(allocator, io, client, token, task, base_env);
        return true;
    }
    try runClaimedTask(allocator, io, client, token, runtime_id, task);
    return true;
}

/// Execute one agent task with the local agent CLI and report it back.
///
/// The payload the server sends is self-contained: the prompt is already
/// rendered, and the agent's configuration (model, environment, extra
/// arguments) travels with it. The daemon never reads the database.
fn executeAgentTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *api.Client,
    token: []const u8,
    task: std.json.Value,
    base_env: ?*const std.process.Environ.Map,
) !void {
    const id = jsonStr(task, "id") orelse return;
    const prompt_text = jsonStr(task, "prompt") orelse "";
    const provider_name = jsonStr(task, "provider") orelse "auto";
    const model = jsonStr(task, "model") orelse "";

    out.printOut("AGENT task id={s} provider={s}\n", .{ id, provider_name });

    const provider = agent_exec.Provider.fromName(provider_name) orelse {
        try failTask(allocator, client, token, id, "no local agent CLI is available");
        return;
    };

    // Tell the server the task is running before the CLI starts: the
    // frontend shows "the agent is working" from exactly that status.
    try startTask(allocator, client, token, id);

    const custom_args = try jsonStringArray(allocator, task, "custom_args");
    defer {
        for (custom_args) |a| allocator.free(a);
        allocator.free(custom_args);
    }

    // The agent gets an empty directory of its own. This fork's agent
    // execution is text-only — the server posts the answer — so the
    // agent has no business in the repository, and an empty directory
    // makes sure it cannot get there.
    const work_dir = ensureTaskWorkDir(allocator, id) catch "";
    defer if (work_dir.len > 0) allocator.free(work_dir);

    const outcome = agent_exec.runAgent(allocator, io, provider, .{
        .prompt = prompt_text,
        .model = model,
        .custom_args = custom_args,
        .custom_env = jsonValue(task, "custom_env"),
        .base_env = base_env,
        .work_dir = work_dir,
    }) catch |err| {
        out.printErr("agent task failed ({s})\n", .{@errorName(err)});
        try failTask(allocator, client, token, id, @errorName(err));
        return;
    };
    // A failed run has no answer. Reporting it through /complete would
    // mark the task successful and post the failure text to the user as
    // if the agent had said it.
    if (outcome.failure) |reason| {
        defer allocator.free(reason);
        try failTask(allocator, client, token, id, reason);
        return;
    }

    try reportTaskOutput(allocator, client, token, id, outcome.output);
}

/// Create the working directory for one agent task.
///
/// The directory is empty on purpose: the agent only has to produce
/// text, and an empty directory keeps it from wandering into the
/// repository (or into unrelated files elsewhere on the machine).
///
/// Returns an empty string when the directory cannot be created — the
/// run then happens in the daemon's own directory, which is worse but
/// not fatal.
fn ensureTaskWorkDir(allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
    if (g_work_root.len == 0) return error.NoWorkRoot;
    makeDir(allocator, g_work_root);
    const dir = try std.fs.path.join(allocator, &.{ g_work_root, task_id });
    errdefer allocator.free(dir);
    makeDir(allocator, dir);
    return dir;
}

/// Create a directory, ignoring the fact that it may already exist.
fn makeDir(allocator: std.mem.Allocator, path: []const u8) void {
    const path_s = allocator.allocSentinel(u8, path.len, 0) catch return;
    defer allocator.free(path_s);
    @memcpy(path_s, path);
    _ = std.c.mkdir(path_s.ptr, 0o700);
}

/// Read a nested JSON value from a task payload.
fn jsonValue(task: std.json.Value, key: []const u8) ?std.json.Value {
    if (task != .object) return null;
    return task.object.get(key);
}

/// Read an array of strings from a task payload.
///
/// Always returns an owned slice (possibly empty) so the caller can free
/// it unconditionally.
fn jsonStringArray(allocator: std.mem.Allocator, task: std.json.Value, key: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    const value = jsonValue(task, key) orelse return list.toOwnedSlice(allocator);
    if (value != .array) return list.toOwnedSlice(allocator);
    for (value.array.items) |item| {
        if (item != .string) continue;
        try list.append(allocator, try allocator.dupe(u8, item.string));
    }
    return list.toOwnedSlice(allocator);
}

/// Tell the server the task started running.
fn startTask(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, task_id: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/tasks/{s}/start", .{task_id});
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, "", token);
    defer resp.deinit();
    if (!resp.ok()) return error.StartFailed;
}

/// Report the agent's answer so the server can deliver it.
fn reportTaskOutput(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, task_id: []const u8, output: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/tasks/{s}/complete", .{task_id});
    defer allocator.free(path);
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .output = output }, .{});
    defer allocator.free(body);
    var resp = try client.postJson(allocator, path, body, token);
    defer resp.deinit();
    if (!resp.ok()) return error.CompleteFailed;
}

/// Execute the task carried by a claim response, if there is one.
fn runClaimedTask(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8, task: std.json.Value) !void {
    if (task != .object) return;

    const id = jsonStr(task, "id") orelse return;
    const task_type = jsonStr(task, "task_type") orelse "unknown";
    const payload = jsonStr(task, "payload") orelse "";

    var id_buf: [128]u8 = undefined;
    const n = @min(id.len, id_buf.len - 1);
    @memcpy(id_buf[0..n], id[0..n]);
    id_buf[n] = 0;

    out.printOut("CLAIMED task id={s} type={s} payload=\"{s}\"\n", .{ id_buf[0..n], task_type, payload });
    executeTask(allocator, io, client, token, runtime_id, id, task_type, payload) catch |err| {
        out.printErr("task execution failed ({s}); marking failed\n", .{@errorName(err)});
        failTask(allocator, client, token, id, @errorName(err)) catch {};
    };
}

/// M4 executor: mark running, execute per task type (payload carries the
/// module request/update id for result reporting), report the result to
/// the module endpoint, then complete.
fn executeTask(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8, task_id: []const u8, task_type: []const u8, payload: []const u8) !void {
    out.printOut("== executing task {s} ({s}) ==\n", .{ task_id, task_type });

    const start_path = try std.fmt.allocPrint(allocator, "/api/daemon/tasks/{s}/start", .{task_id});
    defer allocator.free(start_path);
    var start_resp = try client.postJson(allocator, start_path, "", token);
    defer start_resp.deinit();
    if (!start_resp.ok()) return error.StartFailed;

    if (std.mem.eql(u8, task_type, "update")) {
        try reportUpdate(allocator, client, token, runtime_id, payload);
    } else if (std.mem.eql(u8, task_type, "models")) {
        try reportModels(allocator, client, token, runtime_id, payload);
    } else if (std.mem.eql(u8, task_type, "local_skills")) {
        try reportLocalSkills(allocator, io, client, token, runtime_id, payload);
    } else if (std.mem.eql(u8, task_type, "local_skill_import")) {
        try reportLocalSkillImport(allocator, client, token, runtime_id, payload);
    } else {
        out.printOut("   unknown task type {s} — completing without result\n", .{task_type});
    }

    const complete_path = try std.fmt.allocPrint(allocator, "/api/daemon/tasks/{s}/complete", .{task_id});
    defer allocator.free(complete_path);
    var done = try client.postJson(allocator, complete_path, "", token);
    defer done.deinit();
    if (!done.ok()) return error.CompleteFailed;
    out.printOut("== task {s} completed ==\n", .{task_id});
}

/// update: compare our version with the target; auto-apply lands in M5.
fn reportUpdate(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, runtime_id: []const u8, update_id: []const u8) !void {
    out.printOut("   update: local 1p {s}, target {s}\n", .{ build_options.version, update_id });
    const body = if (std.mem.eql(u8, build_options.version, update_id))
        "{\"output\":\"already up to date\"}"
    else
        "{\"output\":\"target version requires manual update (auto-update lands in M5)\"}";
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/update/{s}/result", .{ runtime_id, update_id });
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, body, token);
    defer resp.deinit();
}

/// models: probe for a local model runtime; report supported + list.
/// For M4 we report an honest empty list (no bundled model runtime yet).
fn reportModels(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, runtime_id: []const u8, request_id: []const u8) !void {
    out.printOut("   models: no local model runtime bundled (M4) — reporting empty list\n", .{});
    const body = "{\"supported\":false,\"models\":[]}";
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/models/{s}/result", .{ runtime_id, request_id });
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, body, token);
    defer resp.deinit();
}

/// local_skills: scan the local skills directory for SKILL.md files.
fn reportLocalSkills(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8, request_id: []const u8) !void {
    const dir_path = "~/.config/1person/skills";
    out.printOut("   local_skills: scanning {s}\n", .{dir_path});
    const skills = scanSkillsDir(io, dir_path);
    out.printOut("   local_skills: found {d}\n", .{skills});
    const body = if (skills > 0)
        "{\"supported\":true,\"skills\":[\"placeholder\"]}"
    else
        "{\"supported\":true,\"skills\":[]}";
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/local-skills/{s}/result", .{ runtime_id, request_id });
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, body, token);
    defer resp.deinit();
}

/// local_skill_import: acknowledge the import (real fetch lands in M5).
fn reportLocalSkillImport(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, runtime_id: []const u8, request_id: []const u8) !void {
    out.printOut("   local_skill_import: acknowledged (real fetch in M5)\n", .{});
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/local-skills/import/{s}/result", .{ runtime_id, request_id });
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, "{}", token);
    defer resp.deinit();
}

/// Count SKILL.md files under the given directory (best-effort; the dir
/// is expected to be absent on fresh installs).
fn scanSkillsDir(io: std.Io, dir_path: []const u8) usize {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, "SKILL.md")) count += 1;
    }
    return count;
}

fn failTask(allocator: std.mem.Allocator, client: *api.Client, token: []const u8, task_id: []const u8, err: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/tasks/{s}/fail", .{task_id});
    defer allocator.free(path);
    // The reason comes from the agent CLI, so it can contain quotes and
    // newlines. It has to be encoded as JSON, not pasted into a literal.
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = err }, .{});
    defer allocator.free(body);
    var resp = try client.postJson(allocator, path, body, token);
    defer resp.deinit();
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn parseHostPort(allocator: std.mem.Allocator, url: []const u8) !struct { host: []const u8, port: u16 } {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const host_port = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |i| after_scheme[0..i] else after_scheme;
    if (std.mem.indexOfScalar(u8, host_port, ':')) |i| {
        const port = std.fmt.parseInt(u16, host_port[i + 1 ..], 10) catch 8080;
        return .{ .host = try allocator.dupe(u8, host_port[0..i]), .port = port };
    }
    return .{ .host = try allocator.dupe(u8, host_port), .port = 8080 };
}
