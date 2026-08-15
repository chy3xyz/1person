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

    // 1. register
    const reg_body = try std.fmt.allocPrint(allocator, "{{\"runtime_id\":\"{s}\"}}", .{opts.runtime_id});
    defer allocator.free(reg_body);
    var reg_resp = try client.postJson(allocator, "/api/daemon/register", reg_body, token_buf);
    defer reg_resp.deinit();
    if (!reg_resp.ok()) {
        out.printErr("register failed (HTTP {d}): {s}\n", .{ reg_resp.status, reg_resp.getString("error") orelse "unknown" });
        return error.RegisterFailed;
    }
    const daemon_id = reg_resp.getString("daemon_id") orelse opts.runtime_id;
    out.printOut("daemon registered: daemon_id={s} runtime_id={s}\n", .{ daemon_id, opts.runtime_id });

    // 2. signal handling for clean shutdown
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // 3. main loop: WS poll + heartbeat + claim
    const host_port = try parseHostPort(allocator, cfg.server_url);
    defer allocator.free(host_port.host);
    const ws_path = try std.fmt.allocPrint(allocator, "/api/daemon/ws?runtime_ids={s}", .{opts.runtime_id});
    defer allocator.free(ws_path);

    var ws_client: ?*ws.Client = null;
    var backoff_ms: u64 = 1000;
    var heartbeat_at: i64 = 0;
    var claim_at: i64 = nowMillis(io) + 3000;

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

        // Claim poll
        if (now >= claim_at) {
            try claimPoll(allocator, io, &client, token_buf, opts.runtime_id);
            claim_at = nowMillis(io) + @as(i64, @intCast(opts.claim_interval_ms));
        }

        // Heartbeat (HTTP + WS frame)
        if (now >= heartbeat_at) {
            heartbeat_at = nowMillis(io) + @as(i64, @intCast(opts.heartbeat_interval_ms));
            var hb = client.postJson(allocator, "/api/daemon/heartbeat", "", token_buf) catch |err| {
                out.printErr("heartbeat failed: {s}\n", .{@errorName(err)});
                continue;
            };
            defer hb.deinit();
            if (ws_client) |c| {
                c.sendText("{\"type\":\"daemon:heartbeat\"}") catch {};
            }
        }

        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    // Deregister on shutdown
    var dr = client.postJson(allocator, "/api/daemon/deregister", "", token_buf) catch null;
    if (dr) |*r| r.deinit();
    out.printOut("daemon stopped\n", .{});
}

/// POST /api/daemon/runtimes/{rid}/tasks/claim; if a task is returned,
/// run the M4 executor (start -> per-type execution -> result report ->
/// complete/fail).
fn claimPoll(allocator: std.mem.Allocator, io: std.Io, client: *api.Client, token: []const u8, runtime_id: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "/api/daemon/runtimes/{s}/tasks/claim", .{runtime_id});
    defer allocator.free(path);
    var resp = try client.postJson(allocator, path, "", token);
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("claim failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return;
    }
    const task = resp.parsed.value.object.get("task") orelse return;
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
