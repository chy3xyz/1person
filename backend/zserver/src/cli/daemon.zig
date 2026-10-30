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
};

var g_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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
    const reg_body = try std.json.Stringify.valueAlloc(allocator, .{
        .runtime_id = opts.runtime_id,
        .cli_version = build_options.version,
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
            const server_up = try claimPoll(allocator, io, &client, token_buf, opts.runtime_id);
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
fn claimPoll(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8) !bool {
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
    const task = resp.parsed.value.object.get("task") orelse return true;
    try runClaimedTask(allocator, io, client, token, runtime_id, task);
    return true;
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
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{err});
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
