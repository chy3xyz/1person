//! Realtime module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs. Realtime is a pure in-memory module with complex
//! state, so `model.zig` has no SQL helpers — `service.zig` is the
//! state + logic home, including the room manager, seq counter, ring
//! buffer, and audit log.
//!
//! The structs that the rest of the codebase needs (`Conn`,
//! `RoomManager`, `RoomManagerMetrics`, `RoomManagerMetricsSnapshot`,
//! `ReplaySnapshot`, `ReplaySnapshotParsed`, plus the `ring_dir` and
//! `audit_dir` path constants) live here so the service layer and
//! test helpers can share a single source of truth.

const std = @import("std");
const zfinal = @import("zfinal");

/// zfinal exposes higher-level WebSocket abstractions, but they manage
/// zfinal.WebSocket streams, which are incompatible with `std.http.Server.WebSocket`
/// returned by `respondWebSocket`. We import them for visibility and
/// implement an equivalent per-workspace room manager around the
/// standard WebSocket type.
pub const WebSocketManager = zfinal.WebSocketManager;
pub const WebSocketConnection = zfinal.WebSocketConnection;

pub const WebSocket = std.http.Server.WebSocket;

/// Token info returned by `authenticate`. The user_id is optional
/// because task, cloud-node, and personal access tokens don't carry
/// one — they're accepted as opaque valid tokens for the realtime
/// endpoint.
pub const TokenInfo = struct {
    user_id: ?[]const u8,
};

/// A single WebSocket connection and its metadata.
pub const Conn = struct {
    allocator: std.mem.Allocator,
    ws: *WebSocket,
    workspace_id: []const u8,
    user_id: ?[]const u8,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    redis_client: ?*zfinal.RedisClient = null,
    thread: ?std.Thread = null,
    /// Milliseconds-since-epoch of the last inbound activity for this
    /// client. Updated by `bumpHeartbeat` on every received frame in
    /// the /ws handler and read by `RoomManager.tick` to drop idle
    /// clients. 0 means "never seen"; new clients are stamped by
    /// `RoomManager.add` so they cannot be evicted on the next tick.
    last_seen_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn bumpHeartbeat(self: *Conn) void {
        const now_ms = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
        self.last_seen_at.store(now_ms, .release);
    }

    pub fn sendRaw(self: *Conn, data: []const u8, op: WebSocket.Opcode) void {
        if (self.closed.load(.acquire)) return;
        self.write_mutex.lockUncancelable(zfinal.io_instance.io);
        defer self.write_mutex.unlock(zfinal.io_instance.io);
        if (self.closed.load(.acquire)) return;
        self.ws.writeMessage(data, op) catch {
            self.closed.store(true, .release);
        };
    }

    pub fn sendText(self: *Conn, text: []const u8) void {
        self.sendRaw(text, .text);
    }

    pub fn sendPong(self: *Conn, data: []const u8) void {
        self.sendRaw(data, .pong);
    }

    /// Signal shutdown. Only flips the flag — the Redis socket is
    /// deliberately left open because the subscriber thread is reading it.
    /// Closing it here would yank the fd out from under an in-flight read
    /// (and the number could be recycled by another thread before the
    /// reader noticed). The subscriber polls `closed` and exits on its
    /// own; the owner joins the thread and only then calls
    /// `redis_client.deinit()`.
    pub fn close(self: *Conn) void {
        self.closed.store(true, .release);
    }
};

/// Idle timeout: clients that haven't sent or received anything
/// within this many milliseconds are pruned from their room on the
/// next `tick` call.
pub const idle_timeout_ms: i64 = 60 * std.time.ms_per_s;

/// Tick stats returned by `RoomManager.tick`.
pub const TickStats = struct {
    pruned_clients: usize = 0,
    pruned_rooms: usize = 0,
};

/// Snapshot of the manager's lifetime counters and the timestamp of
/// the most recent `tick`. Atomically updated so it can be read from
/// the health endpoint without taking the room lock.
pub const RoomManagerMetrics = struct {
    /// `std.Io.Timestamp.now(...).toMilliseconds()` value at the last
    /// tick. `0` when the manager has not ticked yet.
    last_tick_at_ms: i64,
    /// Cumulative number of clients evicted across every tick.
    pruned_clients_total: std.atomic.Value(u64),
    /// Cumulative number of rooms removed (because they became empty).
    pruned_rooms_total: std.atomic.Value(u64),
    /// How many times `tick` has been invoked.
    tick_count: std.atomic.Value(u64),
};

/// Plain-value snapshot returned by `RoomManager.metrics`. We expose
/// a separate type (instead of `RoomManagerMetrics`) so the health
/// endpoint can pass the values straight into `renderJson` without
/// touching the underlying atomics.
pub const RoomManagerMetricsSnapshot = struct {
    last_tick_at_ms: i64 = 0,
    pruned_clients_total: u64 = 0,
    pruned_rooms_total: u64 = 0,
    tick_count: u64 = 0,
};

/// Simple per-workspace room tracker.
pub const RoomManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    rooms: std.StringHashMap(std.ArrayList(*Conn)),
    last_tick_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    pruned_clients_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pruned_rooms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tick_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator) RoomManager {
        return .{
            .allocator = allocator,
            .rooms = std.StringHashMap(std.ArrayList(*Conn)).init(allocator),
        };
    }

    pub fn add(self: *RoomManager, workspace_id: []const u8, conn: *Conn) !void {
        self.mutex.lockUncancelable(zfinal.io_instance.io);
        defer self.mutex.unlock(zfinal.io_instance.io);
        const gop = try self.rooms.getOrPut(workspace_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, workspace_id);
            gop.value_ptr.* = std.ArrayList(*Conn).empty;
        }
        // New clients always start with a fresh heartbeat so they
        // cannot be immediately evicted if their `last_seen_at`
        // defaulted to 0.
        conn.bumpHeartbeat();
        try gop.value_ptr.append(self.allocator, conn);
    }

    pub fn remove(self: *RoomManager, conn: *Conn) void {
        self.mutex.lockUncancelable(zfinal.io_instance.io);
        defer self.mutex.unlock(zfinal.io_instance.io);
        const entry = self.rooms.getEntry(conn.workspace_id) orelse return;
        const list = entry.value_ptr;
        for (list.items, 0..) |c, i| {
            if (c == conn) {
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            // The room's backing storage is allocated with the
            // page allocator (see `ensureManager`), which doesn't
            // track individual frees. Calling `list.deinit` /
            // `self.allocator.free(key)` would run the
            // `Allocator.free` path, which `@memset`s the bytes
            // (poison) before a no-op `rawFree`. If the list was
            // grown with a per-request arena whose lifetime has
            // ended, the poison write segfaults. Skip the deinit:
            // the list and key are bounded by `O(rooms ×
            // connections)` and reclaimed at process exit.
            const key = entry.key_ptr.*;
            _ = self.rooms.fetchRemove(key);
        }
    }

    /// Drop clients whose `last_seen_at` is older than `idle_timeout_ms`
    /// relative to `now_ms`, and remove rooms that have become empty
    /// as a result. Best-effort: evicted clients are marked closed
    /// and removed from the room; the ws handler is responsible for
    /// fully releasing the connection the next time it observes the
    /// close flag.
    pub fn tick(self: *RoomManager, now_ms: i64) TickStats {
        self.mutex.lockUncancelable(zfinal.io_instance.io);
        defer self.mutex.unlock(zfinal.io_instance.io);

        var stats = TickStats{};
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                const c = list.items[i];
                const seen = c.last_seen_at.load(.acquire);
                if (seen != 0 and now_ms - seen >= idle_timeout_ms) {
                    // Mark closed so the readSmallMessage loop bails out.
                    c.closed.store(true, .release);
                    _ = list.orderedRemove(i);
                    stats.pruned_clients += 1;
                    continue;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                // See `remove` for why we don't call
                // `list.deinit` / `self.allocator.free(key)`.
                const key = entry.key_ptr.*;
                _ = self.rooms.fetchRemove(key);
                stats.pruned_rooms += 1;
            }
        }
        // Record lifetime counters + timestamp for the health endpoint.
        // These atomics are updated while still holding the room lock
        // so the timestamp and counts always describe the same tick.
        self.last_tick_at_ms.store(now_ms, .release);
        _ = self.pruned_clients_total.fetchAdd(stats.pruned_clients, .monotonic);
        _ = self.pruned_rooms_total.fetchAdd(stats.pruned_rooms, .monotonic);
        _ = self.tick_count.fetchAdd(1, .monotonic);
        return stats;
    }

    /// Snapshot of the manager's lifetime counters. Atomic loads are
    /// best-effort and tolerate concurrent ticks; readers do not take
    /// the room lock so the health endpoint stays cheap.
    pub fn metrics(self: *const RoomManager) RoomManagerMetricsSnapshot {
        return RoomManagerMetricsSnapshot{
            .last_tick_at_ms = self.last_tick_at_ms.load(.acquire),
            .pruned_clients_total = self.pruned_clients_total.load(.acquire),
            .pruned_rooms_total = self.pruned_rooms_total.load(.acquire),
            .tick_count = self.tick_count.load(.acquire),
        };
    }

    /// Broadcast a JSON-encoded message to every client in the given
    /// workspace room. When the room is empty this is a no-op so the
    /// no-DB path keeps working without errors. The caller is
    /// responsible for checking that the global manager has been
    /// initialised. Opportunistically prunes idle clients before
    /// broadcasting so stale entries don't accumulate.
    pub fn broadcast(self: *RoomManager, workspace_id: []const u8, payload: []const u8) void {
        const now_ms = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
        _ = self.tick(now_ms);
        self.mutex.lockUncancelable(zfinal.io_instance.io);
        defer self.mutex.unlock(zfinal.io_instance.io);
        const entry = self.rooms.getEntry(workspace_id) orelse return;
        // Copy the list so we can release the mutex before sending —
        // writeMessage can block on slow sockets and we don't want to
        // hold the room lock.
        var snapshot: std.ArrayList(*Conn) = .empty;
        defer snapshot.deinit(self.allocator);
        for (entry.value_ptr.items) |c| {
            snapshot.append(self.allocator, c) catch return;
        }
        for (snapshot.items) |c| c.sendText(payload);
    }
};

/// Snapshot returned by `replaySnapshot`. The `envelopes` slice is
/// owned by the caller (free with `allocator.free(envelopes)` after
/// use); the strings it points to remain in the ring buffer and must
/// NOT be freed or mutated by the caller.
pub const ReplaySnapshot = struct {
    envelopes: []const []const u8 = &[_][]const u8{},
    latest_seq: u64 = 0,
    replayed: usize = 0,
};

/// Parsed-replay variant of `ReplaySnapshot`. `events` holds one
/// `std.json.Value` per envelope returned in chronological order;
/// `holders` carries the matching `std.json.Parsed(std.json.Value)`
/// wrappers so the caller can free each arena once it has finished
/// serialising the values (typically inside a `defer` loop at the end
/// of the handler).
///
/// `events[i].value` is owned by `holders[i].arena`; calling
/// `holders[i].deinit()` invalidates `events[i]`. Always render the
/// response *before* iterating the holders.
pub const ReplaySnapshotParsed = struct {
    events: []const std.json.Value = &[_]std.json.Value{},
    holders: []const std.json.Parsed(std.json.Value) = &[_]std.json.Parsed(std.json.Value){},
    latest_seq: u64 = 0,
    replayed: usize = 0,
};

/// On-disk root for the JSONL replay log. One file per
/// `(workspace_id, user_id)`; lines are envelope JSON terminated by
/// `\n`. Lives under `uploads/` so existing container/permission
/// rules already cover it.
pub const ring_dir = "uploads/inbox_ring";

/// On-disk root for the service-action audit log. One file per UTC
/// day, one JSON object per line. Sibling of `ring_dir` so existing
/// container / permission rules for `uploads/` already cover it.
pub const audit_dir = "uploads/audit";
