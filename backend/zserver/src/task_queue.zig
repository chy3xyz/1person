//! Shared in-memory agent task queue for runtime/daemon coordination.

const std = @import("std");
const zfinal = @import("zfinal");

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_tasks: ?std.StringHashMap(TaskEntry) = null;
var mem_messages: ?std.StringHashMap(std.ArrayList([]const u8)) = null;

pub const TaskType = enum {
    update,
    models,
    local_skills,
    local_skill_import,
};

pub const TaskEntry = struct {
    id: []const u8,
    runtime_id: []const u8,
    task_type: TaskType,
    status: []const u8,
    progress: i32,
    payload: []const u8,
    @"error": ?[]const u8,
    session_id: ?[]const u8,
    work_dir: ?[]const u8,
};

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(s: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, s);
}

fn nowNanos() i96 {
    return std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
}

fn generateId(seed: []const u8) ![]const u8 {
    const payload = try std.fmt.allocPrint(memAlloc(), "{s}:{d}", .{ seed, nowNanos() });
    defer memAlloc().free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try memAlloc().alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn memInit() !void {
    if (mem_tasks == null) {
        mem_tasks = std.StringHashMap(TaskEntry).init(memAlloc());
        mem_messages = std.StringHashMap(std.ArrayList([]const u8)).init(memAlloc());
    }
}

pub fn enqueue(runtime_id: []const u8, task_type: TaskType, payload: []const u8) ![]const u8 {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId(runtime_id);
    try mem_tasks.?.put(id, TaskEntry{
        .id = try memDup(id),
        .runtime_id = try memDup(runtime_id),
        .task_type = task_type,
        .status = try memDup("queued"),
        .progress = 0,
        .payload = try memDup(payload),
        .@"error" = null,
        .session_id = null,
        .work_dir = null,
    });
    const dup_id = try memDup(id);
    // Wake any daemon currently watching this runtime over its
    // WebSocket (best-effort; daemons still fall back to HTTP claim).
    @import("daemon_notify.zig").notifyTaskAvailable(runtime_id, dup_id);
    return dup_id;
}

pub fn claim(runtime_id: []const u8) !?TaskEntry {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var it = mem_tasks.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, "queued"))
        {
            e.value_ptr.*.status = try memDup("dispatched");
            return e.value_ptr.*;
        }
    }
    return null;
}

pub fn pending(runtime_id: []const u8, allocator: std.mem.Allocator) ![]TaskEntry {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(TaskEntry) = .empty;
    defer list.deinit(allocator);
    var it = mem_tasks.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.runtime_id, runtime_id) and
            (std.mem.eql(u8, entry.status, "queued") or std.mem.eql(u8, entry.status, "dispatched")))
        {
            try list.append(allocator, entry);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn setStatus(task_id: []const u8, status: []const u8) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_tasks.?.getPtr(task_id)) |entry| {
        entry.status = try memDup(status);
    }
}

pub fn start(task_id: []const u8) !void {
    try setStatus(task_id, "running");
}

pub fn markWaitingLocalDirectory(task_id: []const u8) !void {
    try setStatus(task_id, "waiting_local_directory");
}

pub fn complete(task_id: []const u8) !void {
    try setStatus(task_id, "done");
}

pub fn fail(task_id: []const u8, err_msg: []const u8) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_tasks.?.getPtr(task_id)) |entry| {
        entry.status = try memDup("failed");
        entry.@"error" = try memDup(err_msg);
    }
}

pub fn setProgress(task_id: []const u8, progress: i32) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_tasks.?.getPtr(task_id)) |entry| {
        entry.progress = progress;
    }
}

pub fn getStatus(task_id: []const u8) !?TaskEntry {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    return mem_tasks.?.get(task_id);
}

pub fn addMessages(task_id: []const u8, messages: []const []const u8) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const gop = try mem_messages.?.getOrPut(task_id);
    if (!gop.found_existing) {
        gop.key_ptr.* = try memDup(task_id);
        gop.value_ptr.* = std.ArrayList([]const u8).empty;
    }
    for (messages) |m| {
        try gop.value_ptr.*.append(memAlloc(), try memDup(m));
    }
}

pub fn listMessages(task_id: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const list = mem_messages.?.get(task_id) orelse return &[_][]const u8{};
    return try allocator.dupe([]const u8, list.items);
}

pub fn cancelByRuntime(runtime_id: []const u8) !usize {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var count: usize = 0;
    var it = mem_tasks.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.runtime_id, runtime_id) and
            (std.mem.eql(u8, entry.status, "queued") or std.mem.eql(u8, entry.status, "dispatched")))
        {
            e.value_ptr.*.status = try memDup("cancelled");
            count += 1;
        }
    }
    return count;
}
