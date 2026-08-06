//! Task module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_tasks` +
//! `mem_messages`) and exposes the two user-facing HTTP operations:
//! `listTaskMessagesByUser`, `cancelTaskByUser`. The `handler.zig` is
//! a thin delegate; SQL and data shapes live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.task_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_tasks: ?std.StringHashMap(model.TaskEntry) = null;
var mem_messages: ?std.StringHashMap(std.ArrayList(model.TaskMessageEntry)) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_tasks == null) {
        mem_tasks = std.StringHashMap(model.TaskEntry).init(memAlloc());
    }
    if (mem_messages == null) {
        mem_messages = std.StringHashMap(std.ArrayList(model.TaskMessageEntry)).init(memAlloc());
    }
}

fn memDup(s: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, s);
}

fn nowString() ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real);
    const ms = ts.toMilliseconds();
    const sec = @divFloor(ms, 1000);
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

// ──────────────────────────────────────────────────────────────────────
// list task messages
// ──────────────────────────────────────────────────────────────────────

pub fn listTaskMessagesByUser(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (deps.hasPool()) {
        const issue_id = (try model.dbFetchTaskIssueId(allocator, task_id, workspace_id)) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "task not found" });
            return;
        };
        defer allocator.free(issue_id);

        const items = try model.dbListMessages(allocator, task_id, issue_id);
        defer allocator.free(items);
        try ctx.renderJson(items);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_tasks.?.get(task_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }

    var list: std.ArrayList(model.TaskMessagePayload) = .empty;
    defer list.deinit(allocator);
    const messages = mem_messages.?.get(task_id) orelse std.ArrayList(model.TaskMessageEntry).empty;
    for (messages.items) |m| {
        try list.append(allocator, model.taskMessagePayloadFromEntry(m, entry.issue_id));
    }
    try ctx.renderJson(list.items);
}

// ──────────────────────────────────────────────────────────────────────
// cancel task
// ──────────────────────────────────────────────────────────────────────

pub fn cancelTaskByUser(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (deps.hasPool()) {
        // Confirm the task exists in this workspace before UPDATE
        // (matches legacy behaviour: 404 on missing-or-other-workspace).
        const issue_id = (try model.dbFetchTaskIssueId(ctx.allocator, task_id, workspace_id)) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "task not found" });
            return;
        };
        defer ctx.allocator.free(issue_id);

        var rs = (try model.dbCancelTask(task_id)) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "task not found" });
            return;
        };
        defer rs.deinit();
        try ctx.renderJson(model.taskResponseFromRow(&rs, 0, workspace_id));
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const gop = mem_tasks.?.getOrPut(task_id) catch |err| return err;
    if (!gop.found_existing) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }
    if (!std.mem.eql(u8, gop.value_ptr.*.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }
    memAlloc().free(gop.value_ptr.*.status);
    gop.value_ptr.*.status = try memDup("cancelled");
    memAlloc().free(gop.value_ptr.*.updated_at);
    gop.value_ptr.*.updated_at = try nowString();
    try ctx.renderJson(model.taskResponseFromEntry(gop.value_ptr.*));
}
