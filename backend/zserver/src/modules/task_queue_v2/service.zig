//! Task Queue V2 module — business logic.
//!
//! Owns the per-process state and exposes the queue operations.
//! All state access is mutex-protected. No DB — purely in-memory
//! via the StringHashMap in `model.zig`.
//!
//! Operations:
//!   enqueue  — create a new task (pending)
//!   claim    — pop highest-priority pending task → running
//!   start    — set status to running
//!   complete — set status to done + duration_ms
//!   fail     — set status to failed + duration_ms, bump retries
//!   retry    — if retries < max_retries, set back to pending
//!   list     — filter by workspace_id, optional status, optional priority
//!   stats    — count tasks by status for a workspace

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const model = @import("model.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.task_queue_v2_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

// ──────────────────────────────────────────────────────────────────────
// enqueue
// ──────────────────────────────────────────────────────────────────────

pub fn enqueue(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.EnqueueRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }

    const priority = if (req.priority) |p| model.Priority.fromString(p) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid priority; must be high, medium, or low" });
        return;
    } else model.Priority.medium;

    const payload_json = req.payload_json orelse "{}";
    const run_at_ts = req.run_at_ts orelse 0;
    const max_retries = req.max_retries orelse 0;

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    const id = try model.generateId(model.memAlloc(), name);
    const now = try model.nowString();

    const task = model.Task{
        .id = id,
        .workspace_id = try model.memDup(workspace_id),
        .name = try model.memDup(name),
        .payload_json = try model.memDup(payload_json),
        .priority = priority,
        .status = .pending,
        .run_at_ts = run_at_ts,
        .max_retries = max_retries,
        .retries = 0,
        .duration_ms = null,
        .created_at = try model.memDup(now),
    };

    try model.mem_tasks.?.put(task.id, task);

    ctx.res_status = .created;
    try ctx.renderJson(model.taskResponseFromTask(task));
}

// ──────────────────────────────────────────────────────────────────────
// claim
// ──────────────────────────────────────────────────────────────────────

pub fn claim(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    // Find the highest-priority pending task for this workspace.
    var best_priority: u8 = 0;
    var best_id: ?[]const u8 = null;

    var it = model.mem_tasks.?.iterator();
    while (it.next()) |e| {
        const t = e.value_ptr.*;
        if (!std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
        if (t.status != .pending) continue;
        const rank = t.priority.rank();
        if (rank > best_priority) {
            best_priority = rank;
            best_id = t.id;
        }
    }

    const task_id = best_id orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "no pending tasks" });
        return;
    };

    // Update the task in-place.
    var task_ptr = model.mem_tasks.?.getPtr(task_id).?;
    task_ptr.status = .running;

    try ctx.renderJson(model.taskResponseFromTask(task_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// start
// ──────────────────────────────────────────────────────────────────────

pub fn start(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var task_ptr = model.mem_tasks.?.getPtr(task_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    };
    if (!std.mem.eql(u8, task_ptr.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }

    task_ptr.status = .running;
    try ctx.renderJson(model.taskResponseFromTask(task_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// complete
// ──────────────────────────────────────────────────────────────────────

pub fn complete(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CompleteFailRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var task_ptr = model.mem_tasks.?.getPtr(task_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    };
    if (!std.mem.eql(u8, task_ptr.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }

    task_ptr.status = .done;
    task_ptr.duration_ms = req.duration_ms;
    try ctx.renderJson(model.taskResponseFromTask(task_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// fail
// ──────────────────────────────────────────────────────────────────────

pub fn fail(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CompleteFailRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var task_ptr = model.mem_tasks.?.getPtr(task_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    };
    if (!std.mem.eql(u8, task_ptr.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }

    task_ptr.status = .failed;
    task_ptr.duration_ms = req.duration_ms;
    task_ptr.retries += 1;
    try ctx.renderJson(model.taskResponseFromTask(task_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// retry
// ──────────────────────────────────────────────────────────────────────

pub fn retry(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const task_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var task_ptr = model.mem_tasks.?.getPtr(task_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    };
    if (!std.mem.eql(u8, task_ptr.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "task not found" });
        return;
    }

    if (task_ptr.status != .failed) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "only failed tasks can be retried" });
        return;
    }
    if (task_ptr.retries >= task_ptr.max_retries) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "max retries exceeded" });
        return;
    }

    task_ptr.status = .pending;
    task_ptr.duration_ms = null;
    try ctx.renderJson(model.taskResponseFromTask(task_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// list
// ──────────────────────────────────────────────────────────────────────

pub fn list(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    var filter_status: ?model.Status = null;
    if (try ctx.getPara("status")) |s| {
        filter_status = model.Status.fromString(s);
        if (filter_status == null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid status filter" });
            return;
        }
    }

    var filter_priority: ?model.Priority = null;
    if (try ctx.getPara("priority")) |p| {
        filter_priority = model.Priority.fromString(p);
        if (filter_priority == null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid priority filter" });
            return;
        }
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var list_buf: std.ArrayList(model.TaskResponse) = .empty;
    defer list_buf.deinit(allocator);

    var it = model.mem_tasks.?.iterator();
    while (it.next()) |e| {
        const t = e.value_ptr.*;
        if (!std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
        if (filter_status) |fs| {
            if (t.status != fs) continue;
        }
        if (filter_priority) |fp| {
            if (t.priority != fp) continue;
        }
        try list_buf.append(allocator, model.taskResponseFromTask(t));
    }

    try ctx.renderJson(list_buf.items);
}

// ──────────────────────────────────────────────────────────────────────
// queueStats
// ──────────────────────────────────────────────────────────────────────

pub fn queueStats(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var pending: usize = 0;
    var running: usize = 0;
    var done: usize = 0;
    var failed: usize = 0;
    var total: usize = 0;

    var it = model.mem_tasks.?.iterator();
    while (it.next()) |e| {
        const t = e.value_ptr.*;
        if (!std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
        total += 1;
        switch (t.status) {
            .pending => pending += 1,
            .running => running += 1,
            .done => done += 1,
            .failed => failed += 1,
        }
    }

    try ctx.renderJson(model.QueueStats{
        .pending = pending,
        .running = running,
        .done = done,
        .failed = failed,
        .total = total,
    });
}
