//! Daemon module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_daemons`
//! registry) and the no-DB fallbacks for every route. The actual task
//! queue lives in `src/task_queue.zig` and the runtime result stores
//! live in `src/modules/runtime/service.zig`; the daemon service is
//! the bridge between the HTTP surface and those subsystems.
//!
//! All public functions take `*zfinal.Context` and follow the
//! 1-handler-per-route shape; the corresponding `handler.zig` is a
//! thin delegate. SQL helpers and data structs live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const runtime = @import("../runtime/service.zig");
const task_queue = @import("../../task_queue.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.daemon_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_daemons: ?std.StringHashMap(model.DaemonEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn nowMillis() i64 {
    return std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn memDup(s: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, s);
}

fn jsonObjectGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn memInit() !void {
    if (mem_daemons == null) {
        mem_daemons = std.StringHashMap(model.DaemonEntry).init(memAlloc());
    }
}

// ──────────────────────────────────────────────────────────────────────
// Daemon registry and heartbeat
// ──────────────────────────────────────────────────────────────────────

pub fn daemonRegister(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = try ctx.parseJsonBody(model.DaemonRegisterRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.runtime_id.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    }

    const daemon_id = try generateId(allocator, req.runtime_id);

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const name = if (req.name) |n| try memDup(n) else try memDup("daemon");
    const runtime_id_dup = try memDup(req.runtime_id);
    try mem_daemons.?.put(daemon_id, model.DaemonEntry{
        .id = try memDup(daemon_id),
        .runtime_id = runtime_id_dup,
        .name = name,
        .last_seen_at = nowMillis(),
    });

    try ctx.renderJson(.{
        .daemon_id = daemon_id,
        .runtime_id = req.runtime_id,
    });
}

pub fn daemonDeregister(ctx: *zfinal.Context) !void {
    // The daemon id is carried by the `mdt_<id>` token, not by a
    // path param (Go's `/api/daemon/deregister` is a single endpoint
    // shared by every daemon).
    const daemon_id = ctx.attributes.get("daemon_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_daemons.?.remove(daemon_id);
    try response.okNoContent(ctx);
}

pub fn daemonHeartbeat(ctx: *zfinal.Context) !void {
    const daemon_id = ctx.attributes.get("daemon_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_daemons.?.getPtr(daemon_id)) |entry| {
        entry.last_seen_at = nowMillis();
    }
    try ctx.renderJson(.{ .ok = true });
}

pub fn daemonWebSocket(ctx: *zfinal.Context) !void {
    // Minimal placeholder: accept the connection with an empty body.
    ctx.res_status = .ok;
    try ctx.renderText("");
}

// ──────────────────────────────────────────────────────────────────────
// Workspace repos
// ──────────────────────────────────────────────────────────────────────

pub fn getDaemonWorkspaceRepos(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const raw = model.selectWorkspaceRepos(workspace_id) catch |err| switch (err) {
            error.WorkspaceNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "workspace not found" });
                return;
            },
            else => {
                log.err("getDaemonWorkspaceRepos: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{ .repos = raw });
    } else {
        try ctx.renderJson(.{ .repos = "[]" });
    }
}

// ──────────────────────────────────────────────────────────────────────
// Async runtime result reporting
// ──────────────────────────────────────────────────────────────────────

pub fn reportUpdateResult(ctx: *zfinal.Context) !void {
    const update_id = ctx.getPathParam("updateId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "update_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.updateStoreFail(update_id, err);
        } else {
            const output = jsonObjectGetString(req.object, "output") orelse "ok";
            runtime.updateStoreComplete(update_id, output);
        }
    } else {
        runtime.updateStoreComplete(update_id, "ok");
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportModelListResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.modelStoreFail(request_id, err);
        } else {
            const supported = if (req.object.get("supported")) |v| v == .bool and v.bool else false;
            runtime.modelStoreComplete(request_id, &[_]runtime.ModelEntry{}, supported);
        }
    } else {
        runtime.modelStoreComplete(request_id, &[_]runtime.ModelEntry{}, false);
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportLocalSkillListResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.localSkillStoreFail(request_id, err);
        } else {
            const supported = if (req.object.get("supported")) |v| v == .bool and v.bool else false;
            runtime.localSkillStoreComplete(request_id, &[_]runtime.RuntimeLocalSkillSummary{}, supported);
        }
    } else {
        runtime.localSkillStoreComplete(request_id, &[_]runtime.RuntimeLocalSkillSummary{}, false);
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportLocalSkillImportResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.localImportStoreFail(request_id, err);
        } else {
            runtime.localImportStoreComplete(request_id, std.json.Value{ .null = {} });
        }
    } else {
        runtime.localImportStoreComplete(request_id, std.json.Value{ .null = {} });
    }
    try ctx.renderJson(.{ .success = true });
}

// ──────────────────────────────────────────────────────────────────────
// Task lifecycle
// ──────────────────────────────────────────────────────────────────────

pub fn getTaskStatus(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectTaskStatus(task_id) catch |err| switch (err) {
            error.TaskNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "task not found" });
                return;
            },
            else => {
                log.err("getTaskStatus: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .task_id = task_id,
            .status = row.status,
            .@"error" = row.@"error",
        });
    } else {
        const entry = try task_queue.getStatus(task_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "task not found" });
            return;
        };
        try ctx.renderJson(.{
            .task_id = task_id,
            .status = entry.status,
            .@"error" = entry.@"error",
        });
    }
}

pub fn claimTaskByRuntime(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    const task = try task_queue.claim(runtime_id);
    if (task) |t| {
        try ctx.renderJson(.{ .task = t });
    } else {
        try ctx.renderJson(.{ .task = null });
    }
}

pub fn listPendingTasksByRuntime(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    const tasks = try task_queue.pending(runtime_id, allocator);
    defer allocator.free(tasks);
    try ctx.renderJson(.{ .tasks = tasks });
}

pub fn startTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    try task_queue.start(task_id);
    try ctx.renderJson(.{ .success = true });
}

pub fn markTaskWaitingLocalDirectory(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    try task_queue.markWaitingLocalDirectory(task_id);
    try ctx.renderJson(.{ .success = true });
}

pub fn reportTaskProgress(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.TaskProgressRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try task_queue.setProgress(task_id, req.progress orelse 0);
    try ctx.renderJson(.{ .success = true });
}

pub fn completeTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    try task_queue.complete(task_id);
    try ctx.renderJson(.{ .success = true });
}

pub fn failTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.TaskFailRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try task_queue.fail(task_id, req.@"error" orelse "unknown error");
    try ctx.renderJson(.{ .success = true });
}

pub fn reportTaskUsage(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    _ = task_id;
    const parsed = try ctx.parseJsonBody(model.TaskUsageRequest);
    defer parsed.deinit();
    _ = parsed.value;
    try ctx.renderJson(.{ .success = true });
}

pub fn reportTaskMessages(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.TaskMessagesRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const messages = req.messages orelse &[_][]const u8{};
    try task_queue.addMessages(task_id, messages);
    try ctx.renderJson(.{ .success = true });
}

pub fn listTaskMessages(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    const messages = try task_queue.listMessages(task_id, allocator);
    defer allocator.free(messages);
    try ctx.renderJson(messages);
}

// ──────────────────────────────────────────────────────────────────────
// GC checks
// ──────────────────────────────────────────────────────────────────────

pub fn getIssueGCCheck(ctx: *zfinal.Context) !void {
    const issue_id = ctx.getPathParam("issueId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectIssueGCCheck(issue_id) catch |err| switch (err) {
            error.IssueNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "issue not found" });
                return;
            },
            else => {
                log.err("getIssueGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .updated_at = row.updated_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "backlog", .updated_at = null });
    }
}

pub fn getChatSessionGCCheck(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectChatSessionGCCheck(session_id) catch |err| switch (err) {
            error.ChatSessionNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "chat session not found" });
                return;
            },
            else => {
                log.err("getChatSessionGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .updated_at = row.updated_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "active", .updated_at = null });
    }
}

pub fn getAutopilotRunGCCheck(ctx: *zfinal.Context) !void {
    const run_id = ctx.getPathParam("runId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "run_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectAutopilotRunGCCheck(run_id) catch |err| switch (err) {
            error.AutopilotRunNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "autopilot run not found" });
                return;
            },
            else => {
                log.err("getAutopilotRunGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .completed_at = row.completed_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "pending", .completed_at = null });
    }
}

pub fn getTaskGCCheck(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const status = model.selectTaskGCCheck(task_id) catch |err| switch (err) {
            error.TaskNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "task not found" });
                return;
            },
            else => {
                log.err("getTaskGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{ .status = status });
    } else {
        try ctx.renderJson(.{ .status = "queued" });
    }
}

pub fn recoverOrphanedTasks(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const cancelled = try task_queue.cancelByRuntime(runtime_id);
    try ctx.renderJson(.{ .recovered = cancelled });
}

pub fn pinTaskSession(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.PinTaskSessionRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.session_id == null and req.work_dir == null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id or work_dir required" });
        return;
    }

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        if (req.session_id) |sid| {
            if (req.work_dir) |wd| {
                model.pinSessionAndWorkDir(task_id, sid, wd) catch |err| {
                    log.err("pinTaskSession: {}", .{err});
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "database_error" });
                    return;
                };
            } else {
                model.pinSession(task_id, sid) catch |err| {
                    log.err("pinTaskSession: {}", .{err});
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "database_error" });
                    return;
                };
            }
        } else if (req.work_dir) |wd| {
            model.pinWorkDir(task_id, wd) catch |err| {
                log.err("pinTaskSession: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
        }
    }
    ctx.res_status = .no_content;
}
