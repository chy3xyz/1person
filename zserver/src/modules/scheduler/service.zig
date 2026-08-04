//! Scheduler service — in-memory CRUD for scheduled tasks.
//!
//! Operates entirely in no-DB mode using a page-allocator-backed
//! StringHashMap. All per-workspace scoping is enforced.
//! Execution simulation: pending → done (or failed).

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const ScheduledTask = model.ScheduledTask;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_tasks: ?std.StringHashMap(model.ScheduledTask) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_tasks == null) {
        mem_tasks = std.StringHashMap(model.ScheduledTask).init(memAlloc());
    }
}

fn generateId() ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "sched-{d}", .{ts});
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

fn dupDependsOn(deps: []const []const u8) ![]const []const u8 {
    if (deps.len == 0) return &[_][]const u8{};
    const out = try memAlloc().alloc([]const u8, deps.len);
    for (deps, 0..) |d, i| {
        out[i] = try memDup(d);
    }
    return out;
}

// ── Schedule (create pending task) ──────────────────────────────

pub fn scheduleTask(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.ScheduleTaskRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }

    try memInit();

    const id = try generateId();
    const entry = model.ScheduledTask{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .payload_json = try memDup(req.payload_json),
        .run_at_ts = req.run_at_ts,
        .status = try memDup("pending"),
        .retries = 0,
        .max_retries = req.max_retries,
        .depends_on = try dupDependsOn(req.depends_on),
        .created_at = try nowStr(),
    };

    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        try mem_tasks.?.put(entry.id, entry);
    }

    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

// ── Get task by ID ──────────────────────────────────────────────

pub fn getTask(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = try response.parseStringId(ctx, "id");
    try memInit();

    var task_opt: ?model.ScheduledTask = null;
    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        if (mem_tasks.?.get(id)) |entry| {
            task_opt = entry;
        }
    }

    const entry = task_opt orelse {
        try response.err(ctx, .not_found, "scheduled task not found", 40401);
        return;
    };
    try ctx.renderJson(entry);
}

// ── List tasks (with optional ?status= filter) ─────────────────

pub fn listTasks(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const status_filter = response.queryParam(ctx, "status");

    try memInit();

    var list: std.ArrayList(model.ScheduledTask) = .empty;
    defer list.deinit(ctx.allocator);
    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        if (mem_tasks) |*m| {
            var it = m.iterator();
            while (it.next()) |kv| {
                const t = kv.value_ptr.*;
                if (!std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
                if (status_filter) |sf| {
                    if (!std.mem.eql(u8, t.status, sf)) continue;
                }
                try list.append(ctx.allocator, t);
            }
        }
    }
    try ctx.renderJson(.{ .tasks = list.items, .total = list.items.len });
}

// ── Execute now (simulate: pending → done) ─────────────────────

pub fn executeNow(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = try response.requireQuery(ctx, "id");

    // Optional ?fail=1 to simulate failure
    const should_fail = if (response.queryParam(ctx, "fail")) |v|
        std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")
    else
        false;

    try memInit();

    var task_copy: model.ScheduledTask = undefined;
    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_tasks.?.getPtr(id) orelse {
            try response.err(ctx, .not_found, "scheduled task not found", 40401);
            return;
        };

        if (!std.mem.eql(u8, entry_ptr.status, "pending")) {
            try response.err(ctx, .conflict, "task is not in pending status", 40901);
            return;
        }

        if (should_fail) {
            entry_ptr.status = try memDup("failed");
        } else {
            entry_ptr.status = try memDup("done");
        }

        // Get fresh copy via .get() for clean rendering
        task_copy = mem_tasks.?.get(id).?;
    }

    ctx.res_status = .ok;
    try ctx.renderJson(task_copy);
}

// ── Cancel task ─────────────────────────────────────────────────

pub fn cancelTask(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = try response.requireQuery(ctx, "id");

    try memInit();

    var task_copy: model.ScheduledTask = undefined;
    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_tasks.?.getPtr(id) orelse {
            try response.err(ctx, .not_found, "scheduled task not found", 40401);
            return;
        };

        if (!std.mem.eql(u8, entry_ptr.status, "pending") and !std.mem.eql(u8, entry_ptr.status, "running")) {
            try response.err(ctx, .conflict, "task cannot be cancelled in current status", 40901);
            return;
        }

        entry_ptr.status = try memDup("cancelled");
        task_copy = mem_tasks.?.get(id).?;
    }

    try ctx.renderJson(task_copy);
}

// ── Retry failed task ───────────────────────────────────────────

pub fn retryTask(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = try response.requireQuery(ctx, "id");

    try memInit();

    var task_copy: model.ScheduledTask = undefined;
    {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_tasks.?.getPtr(id) orelse {
            try response.err(ctx, .not_found, "scheduled task not found", 40401);
            return;
        };

        if (!std.mem.eql(u8, entry_ptr.status, "failed")) {
            try response.err(ctx, .conflict, "task is not in failed status", 40901);
            return;
        }

        if (entry_ptr.retries >= entry_ptr.max_retries) {
            try response.err(ctx, .conflict, "max retries reached", 40902);
            return;
        }

        entry_ptr.retries += 1;
        entry_ptr.status = try memDup("pending");
        task_copy = mem_tasks.?.get(id).?;
    }

    try ctx.renderJson(task_copy);
}
