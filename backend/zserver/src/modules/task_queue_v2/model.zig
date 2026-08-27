//! Task Queue V2 module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and the in-memory store. `service.zig` wraps this
//! with the business logic for the no-DB queue path.
//!
//! This is a general-purpose task queue with priority ordering and
//! mutex-protected in-memory storage.

const std = @import("std");
const zfinal = @import("zfinal");

pub const Priority = enum {
    high,
    medium,
    low,

    pub fn fromString(s: []const u8) ?Priority {
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "low")) return .low;
        return null;
    }

    pub fn toString(self: Priority) []const u8 {
        return switch (self) {
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }

    pub fn rank(self: Priority) u8 {
        return switch (self) {
            .high => 3,
            .medium => 2,
            .low => 1,
        };
    }
};

pub const Status = enum {
    pending,
    running,
    done,
    failed,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .done => "done",
            .failed => "failed",
        };
    }
};

/// In-memory task row.
pub const Task = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    payload_json: []const u8,
    priority: Priority,
    status: Status,
    run_at_ts: i64,
    max_retries: u32,
    retries: u32,
    duration_ms: ?i64,
    created_at: []const u8,
};

/// API response shape for a task.
pub const TaskResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    payload_json: []const u8,
    priority: []const u8,
    status: []const u8,
    run_at_ts: i64,
    max_retries: u32,
    retries: u32,
    duration_ms: ?i64,
    created_at: []const u8,
};

/// Request body for `POST /api/task-queue` (enqueue).
pub const EnqueueRequest = struct {
    name: []const u8,
    payload_json: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    run_at_ts: ?i64 = null,
    max_retries: ?u32 = null,
};

/// Request body for `POST /api/task-queue/:id/complete` and `.../:id/fail`.
pub const CompleteFailRequest = struct {
    duration_ms: ?i64 = null,
};

/// Stats response for GET /api/task-queue/stats.
pub const QueueStats = struct {
    pending: usize,
    running: usize,
    done: usize,
    failed: usize,
    total: usize,
};

/// ─── in-memory store (module-scoped, mutex-protected by service.zig) ───

pub var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
pub var mem_tasks: ?std.StringHashMap(Task) = null;

pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn memInit() !void {
    if (mem_tasks == null) {
        mem_tasks = std.StringHashMap(Task).init(memAlloc());
    }
}

pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

/// Stable pseudo-UUID for the in-memory store.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 36);
    const charset = "0123456789abcdef";
    var o: usize = 0;
    for (hash[0..16], 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            hex[o] = '-';
            o += 1;
        }
        hex[o] = charset[b >> 4];
        hex[o + 1] = charset[b & 0x0f];
        o += 2;
    }
    return hex;
}

pub fn taskResponseFromTask(task: Task) TaskResponse {
    return TaskResponse{
        .id = task.id,
        .workspace_id = task.workspace_id,
        .name = task.name,
        .payload_json = task.payload_json,
        .priority = task.priority.toString(),
        .status = task.status.toString(),
        .run_at_ts = task.run_at_ts,
        .max_retries = task.max_retries,
        .retries = task.retries,
        .duration_ms = task.duration_ms,
        .created_at = task.created_at,
    };
}
