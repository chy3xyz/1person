//! Registry of live daemon WebSocket connections, keyed by runtime id.
//!
//! Lets `task_queue.enqueue` push `daemon:task_available` frames to the
//! daemon currently watching a runtime, without importing the daemon
//! module (which would create an import cycle: daemon -> task_queue).
//!
//! The daemon WS handler (`daemon/service.zig::daemonWebSocket`)
//! registers the connection after the handshake and unregisters it when
//! the read loop exits. Connections are stored as raw `*WebSocket`
//! pointers that stay valid for the handler's lifetime (the handler
//! blocks in `readSmallMessage` until the socket closes).

const std = @import("std");
const zfinal = @import("zfinal");

pub const WebSocket = std.http.Server.WebSocket;

var registry: ?std.StringHashMap(*WebSocket) = null;
var mutex: std.Io.Mutex = std.Io.Mutex.init;

fn ensureRegistry() void {
    if (registry == null) {
        registry = std.StringHashMap(*WebSocket).init(std.heap.page_allocator);
    }
}

/// Register a daemon's connection for the given runtime ids. Called by
/// the daemon WS handler after the handshake; `unregister` must be
/// called when the connection closes.
pub fn register(runtime_ids: []const []const u8, ws: *WebSocket) void {
    mutex.lockUncancelable(zfinal.io_instance.io);
    defer mutex.unlock(zfinal.io_instance.io);
    ensureRegistry();
    for (runtime_ids) |rid| {
        if (rid.len == 0) continue;
        const key = std.heap.page_allocator.dupe(u8, rid) catch continue;
        registry.?.put(key, ws) catch {
            std.heap.page_allocator.free(key);
        };
    }
}

/// Drop the connection from the registry. Called when the daemon WS
/// read loop exits.
pub fn unregister(runtime_ids: []const []const u8, ws: *WebSocket) void {
    mutex.lockUncancelable(zfinal.io_instance.io);
    defer mutex.unlock(zfinal.io_instance.io);
    if (registry == null) return;
    for (runtime_ids) |rid| {
        if (rid.len == 0) continue;
        if (registry.?.getPtr(rid)) |ptr| {
            if (ptr.* == ws) {
                if (registry.?.fetchRemove(rid)) |kv| std.heap.page_allocator.free(kv.key);
            }
        }
    }
}

/// Push a `daemon:task_available` frame to the daemon watching
/// `runtime_id` (if any). Best-effort: a failed write drops the entry
/// so we don't spin on a closed fd.
pub fn notifyTaskAvailable(runtime_id: []const u8, task_id: []const u8) void {
    mutex.lockUncancelable(zfinal.io_instance.io);
    defer mutex.unlock(zfinal.io_instance.io);
    if (registry == null) return;
    const ws = registry.?.get(runtime_id) orelse return;
    const payload = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"type\":\"daemon:task_available\",\"task_id\":\"{s}\"}}",
        .{task_id},
    ) catch return;
    defer std.heap.page_allocator.free(payload);
    ws.writeMessage(payload, .text) catch {
        if (registry.?.fetchRemove(runtime_id)) |kv| std.heap.page_allocator.free(kv.key);
    };
}
