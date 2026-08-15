//! Realtime module — business logic.
//!
//! Owns the per-process state for the WebSocket realtime plane:
//!   * `g_manager: ?RoomManager` — the per-workspace room manager that
//!     fan-outs broadcasts and prunes idle clients.
//!   * `g_seq_map: ?std.StringHashMap(std.atomic.Value(u64))` — the
//!     per-`(workspace, user)` monotonic seq counter, bumped by
//!     `publishInbox`.
//!   * `g_ring_map: ?std.StringHashMap(std.ArrayList([]u8))` — the
//!     per-pair ring buffer of recent envelope JSON strings, backed
//!     by an on-disk JSONL log under `uploads/inbox_ring/`.
//!   * The audit log under `uploads/audit/` for privileged
//!     admin/service actions (purge, export, …).
//!
//! The HTTP-side exports (`publishInbox`, `publishChatMessage`,
//! `roomCount`, `clientCount`, `metrics`, `purgePair`,
//! `appendAudit`, `replaySnapshot`, `replaySnapshotParsed`,
//! `ringApproxBytes`, `latestSeq`, `replaySince`, `replaySinceStream`,
//! `clearRingForTest`, `readTailJsonl`, `readTodayAuditLines`) are
//! the public API other modules (chat, inbox, health_realtime) and
//! the unit tests use. The `handler.zig` is a thin delegate for the
//! one HTTP route — `handleRealtime` — which is wired inline in
//! `src/router.zig::registerAll` rather than via the module's
//! `routes.zig::register`.

const std = @import("std");
const zfinal = @import("zfinal");
const auth = @import("../../auth.zig");
const redis = @import("../../redis.zig");
const workspace = @import("../workspace/model.zig");
const model = @import("model.zig");

const log = std.log.scoped(.realtime);

/// Global room manager. Public so the health endpoint can read the
/// `metrics()` snapshot; null when no websocket has ever been opened
/// (no-DB fallback path).
pub var g_manager: ?model.RoomManager = null;
var g_manager_mutex: std.Io.Mutex = .init;

/// Per-workspace + per-user inbox seq counter. Keyed by
/// `workspace_id|user_id` (UUIDs, so the separator never collides).
/// The counter is only bumped from `publishInbox`, which is already
/// guarded by the manager-mutex path, so concurrent inserts are
/// protected by `g_seq_mutex` and the per-pair `std.atomic.Value(u64)`
/// makes the read in `latestSeq` lock-free.
var g_seq_mutex: std.Io.Mutex = .init;
var g_seq_map: ?std.StringHashMap(std.atomic.Value(u64)) = null;

/// Capacity of the per-(workspace, user) inbox event ring buffer.
/// The `replaySince` endpoint uses this to recover missed events for
/// clients reconnecting with a stale `since_seq`. Kept small (64) so
/// a single abusive workspace can't bloat process memory.
const RingCap: usize = 64;

/// Per-(workspace, user) ring buffer of recent envelope JSON strings.
/// Keyed by the same `workspace_id|user_id` string used by
/// `g_seq_map`. Each value is an ordered list of envelope JSON
/// strings; the oldest entry is dropped once the list grows past
/// `RingCap`. The buffer lives for the process lifetime — entries
/// are leaked on shutdown, which is fine for a foreground server.
var g_ring_mutex: std.Io.Mutex = .init;
var g_ring_map: ?std.StringHashMap(std.ArrayList([]u8)) = null;

fn ensureSeqMap(allocator: std.mem.Allocator) !void {
    if (g_seq_map == null) {
        g_seq_map = std.StringHashMap(std.atomic.Value(u64)).init(allocator);
    }
}

fn ensureRingMap(allocator: std.mem.Allocator) !void {
    if (g_ring_map == null) {
        g_ring_map = std.StringHashMap(std.ArrayList([]u8)).init(allocator);
    }
}

/// Pick the allocator backing the global seq/ring maps. Prefer the
/// RoomManager's allocator when a WebSocket has been opened (so we
/// share its lifetime); fall back to `page_allocator` for the
/// no-WS / no-DB path. The maps and their keys/values are tiny and
/// live forever, so leaking them is acceptable.
fn globalMapAllocator() std.mem.Allocator {
    if (g_manager) |*m| return m.allocator;
    return std.heap.page_allocator;
}

/// Build the map key. Caller owns the returned slice.
fn seqKeyAlloc(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ workspace_id, user_id });
}

/// Atomically increment the (workspace, user) seq counter and return
/// the new value (1-based). Best-effort: returns 0 on alloc failure
/// so callers can choose to skip the `seq` field rather than
/// dropping the event.
fn nextSeq(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8) u64 {
    g_seq_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_seq_mutex.unlock(zfinal.io_instance.io);
    ensureSeqMap(allocator) catch return 0;
    const key = seqKeyAlloc(allocator, workspace_id, user_id) catch return 0;
    defer allocator.free(key);
    const gop = g_seq_map.?.getOrPut(key) catch return 0;
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, key) catch return 0;
        gop.value_ptr.* = std.atomic.Value(u64).init(0);
    }
    return gop.value_ptr.fetchAdd(1, .monotonic) + 1;
}

/// Push a fully-rendered envelope JSON string into the ring buffer
/// for the given (workspace, user) pair. Best-effort: alloc failures
/// are silently dropped so `publishInbox` never has to unwind. Once
/// the buffer exceeds `RingCap` entries the oldest one is freed and
/// removed. Also appends the envelope to the per-(workspace, user)
/// JSONL log on disk so a restarted server can re-hydrate the
/// in-memory ring.
fn pushEnvelope(workspace_id: []const u8, user_id: []const u8, envelope: []const u8) void {
    const allocator = globalMapAllocator();
    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_ring_mutex.unlock(zfinal.io_instance.io);
    ensureRingMap(allocator) catch return;
    const key = seqKeyAlloc(allocator, workspace_id, user_id) catch return;
    defer allocator.free(key);
    const gop = g_ring_map.?.getOrPut(key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, key) catch return;
        gop.value_ptr.* = .empty;
        // Hydrate the ring from disk before the first push so a
        // server restart preserves up to `RingCap` recent envelopes.
        hydrateRingLocked(allocator, gop.value_ptr, workspace_id, user_id);
    }
    const list = gop.value_ptr;
    // Copy the envelope into the map's allocator so the caller's
    // buffer (typically a `defer allocator.free(env)` in
    // `publishInbox`) can be reclaimed without affecting the ring
    // buffer.
    const owned = allocator.dupe(u8, envelope) catch return;
    list.append(allocator, owned) catch {
        allocator.free(owned);
        return;
    };
    if (list.items.len > RingCap) {
        const dropped = list.orderedRemove(0);
        allocator.free(dropped);
    }
    // Append to the JSONL log after the in-memory state is
    // consistent. The lock is still held so concurrent writers do
    // not interleave.
    appendEnvelopeJsonl(workspace_id, user_id, envelope);
}

/// Build the JSONL log path for a `(workspace_id, user_id)` pair
/// into a caller-provided buffer. Returns the slice of `buf` that
/// was written.
fn jsonlPath(buf: []u8, workspace_id: []const u8, user_id: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}.jsonl", .{ model.ring_dir, workspace_id, user_id }) catch return error.PathTooLong;
}

/// Append a single envelope to the JSONL log for the given pair.
/// Best-effort: any I/O or allocation failure is silently swallowed
/// so the in-memory ring buffer remains the source of truth. Uses
/// `File.writePositionalAll` with the current file size as the
/// offset so the write is always append-only.
fn appendEnvelopeJsonl(workspace_id: []const u8, user_id: []const u8, envelope: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = jsonlPath(&path_buf, workspace_id, user_id) catch return;

    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ model.ring_dir, workspace_id }) catch return;
    std.Io.Dir.cwd().createDirPath(zfinal.io_instance.io, dir_path) catch return;

    var file = std.Io.Dir.cwd().createFile(zfinal.io_instance.io, path, .{ .truncate = false }) catch return;
    defer file.close(zfinal.io_instance.io);

    const stat = file.stat(zfinal.io_instance.io) catch return;
    var line_buf: [4096]u8 = undefined;
    const with_nl = std.fmt.bufPrint(&line_buf, "{s}\n", .{envelope}) catch return;
    std.Io.File.writePositionalAll(file, zfinal.io_instance.io, with_nl, stat.size) catch return;
}

/// Populate `list` (already allocated, may be empty) with the last
/// `RingCap` envelope lines from the JSONL log. The caller must hold
/// `g_ring_mutex`. Errors are swallowed; partial hydration is
/// acceptable.
fn hydrateRingLocked(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), workspace_id: []const u8, user_id: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = jsonlPath(&path_buf, workspace_id, user_id) catch return;
    var file = std.Io.Dir.cwd().openFile(zfinal.io_instance.io, path, .{}) catch return;
    defer file.close(zfinal.io_instance.io);

    const stat = file.stat(zfinal.io_instance.io) catch return;
    const size: usize = @intCast(stat.size);
    if (size == 0) return;
    // Cap hydration at 4 MB to avoid OOM on a corrupted / huge log.
    if (size > 4 * 1024 * 1024) return;

    const buf = allocator.alloc(u8, size) catch return;
    defer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(zfinal.io_instance.io, &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const m = rdr.interface.readSliceShort(buf[offset..]) catch break;
        if (m == 0) break;
        offset += m;
    }
    if (offset != size) return;

    var lines: std.ArrayList([]u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, buf[0..offset], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const dup = allocator.dupe(u8, line) catch continue;
        lines.append(allocator, dup) catch {
            allocator.free(dup);
            continue;
        };
    }
    const start = if (lines.items.len > RingCap) lines.items.len - RingCap else 0;
    for (lines.items[start..]) |env| {
        list.append(allocator, env) catch {
            allocator.free(env);
            return;
        };
    }
}

/// Public helper for tests: read all lines from the JSONL log for
/// the given pair. Caller owns the returned slice of strings and the
/// inner strings; free with `allocator.free` and per-line
/// `allocator.free`.
pub fn readTailJsonl(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8) ![]const []u8 {
    var path_buf: [256]u8 = undefined;
    const path = try jsonlPath(&path_buf, workspace_id, user_id);
    var file = std.Io.Dir.cwd().openFile(zfinal.io_instance.io, path, .{}) catch return &[_][]u8{};
    defer file.close(zfinal.io_instance.io);
    const stat = file.stat(zfinal.io_instance.io) catch return &[_][]u8{};
    const size: usize = @intCast(stat.size);
    if (size == 0) return &[_][]u8{};
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(zfinal.io_instance.io, &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const m = rdr.interface.readSliceShort(buf[offset..]) catch break;
        if (m == 0) break;
        offset += m;
    }
    var out: std.ArrayList([]u8) = .empty;
    var it = std.mem.splitScalar(u8, buf[0..offset], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const dup = try allocator.dupe(u8, line);
        try out.append(allocator, dup);
    }
    return out.toOwnedSlice(allocator);
}

/// Test helper: delete the JSONL log and drop the in-memory ring
/// entry for the given pair so a subsequent `publishInbox` starts
/// from a clean slate. Best-effort: missing files or absent map
/// entries are ignored.
pub fn clearRingForTest(workspace_id: []const u8, user_id: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = jsonlPath(&path_buf, workspace_id, user_id) catch return;
    std.Io.Dir.cwd().deleteFile(zfinal.io_instance.io, path) catch {};
    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_ring_mutex.unlock(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(std.heap.page_allocator, workspace_id, user_id)) |key| {
            defer std.heap.page_allocator.free(key);
            _ = map.remove(key);
        } else |_| {}
    }
}

/// Admin helper: delete the JSONL log and drop both the in-memory
/// ring entry and the per-pair seq counter for the given
/// `(workspace_id, user_id)` pair so a subsequent `publishInbox`
/// starts from a clean slate. Best-effort: missing files or absent
/// map entries are silently ignored so the no-DB fallback path keeps
/// working. The string slices stored inside the ring list are freed
/// so the per-process allocator doesn't accumulate orphans across
/// repeated purges.
///
/// Pair ordering: ring map first, then seq map. We hold each mutex
/// independently and only as long as needed; the two maps have no
/// cross-dependency so a deadlock can't occur.
pub fn purgePair(workspace_id: []const u8, user_id: []const u8) void {
    var path_buf: [256]u8 = undefined;
    if (jsonlPath(&path_buf, workspace_id, user_id)) |path| {
        std.Io.Dir.cwd().deleteFile(zfinal.io_instance.io, path) catch {};
    } else |_| {}

    const allocator = globalMapAllocator();

    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_ring_mutex.unlock(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.fetchRemove(key)) |kv| {
                const key_owned = kv.key;
                // `fetchRemove` exposes the value as an rvalue; rebind
                // to a mutable `var` so we can hand a `*Self` to
                // `ArrayList.deinit` and release its underlying
                // buffer. The per-envelope strings are freed below.
                var list = kv.value;
                for (list.items) |env| allocator.free(env);
                list.deinit(allocator);
                allocator.free(key_owned);
            }
        } else |_| {}
    }

    g_seq_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_seq_mutex.unlock(zfinal.io_instance.io);
    if (g_seq_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
            }
        } else |_| {}
    }

    log.info("purged inbox ring workspace={s} user={s}", .{ workspace_id, user_id });
}

/// Filename for a given UTC date (`YYYY-MM-DD`). Caller owns the
/// buffer.
fn auditFileName(buf: []u8, date_str: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.jsonl", .{ model.audit_dir, date_str }) catch return error.PathTooLong;
}

/// Full path for today's audit file into a caller-provided buffer.
fn todayAuditPath(buf: []u8) ![]u8 {
    var date_buf: [16]u8 = undefined;
    const date = todayUtcDate(&date_buf) catch return error.PathTooLong;
    return auditFileName(buf, date);
}

/// Today's UTC date as `YYYY-MM-DD` into a caller-provided buffer.
/// Best-effort: returns error on buffer overflow so the caller can
/// surface it without panicking.
fn todayUtcDate(buf: *[16]u8) ![]u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    });
}

/// RFC3339 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`) for "now" into a
/// caller-provided buffer. Mirrors the helper used in `webhook.zig`
/// so the audit log lines use the same wire format as the rest of
/// the service.
fn nowRfc3339Utc(buf: *[32]u8) ![]u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sd = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        sd.getHoursIntoDay(),
        sd.getMinutesIntoHour(),
        sd.getSecondsIntoMinute(),
    });
}

/// Append one audit line for a privileged action (e.g. an inbox
/// purge triggered by a workspace admin or service token) to the
/// per-day JSONL log under `uploads/audit/`. The parent directory
/// is created on demand and the file is opened with `truncate =
/// false` so writes are appended atomically via
/// `writePositionalAll`.
///
/// Fields written (matching the spec'd wire shape):
///   `ts`              — RFC3339 UTC timestamp of the call
///   `actor`           — caller kind (`service_actor` or workspace role)
///   `user_id`         — actor's user id if present (empty otherwise)
///   `action`          — short action verb (e.g. `inbox.purge`)
///   `workspace_id`    — workspace the action targets
///   `target_user_id`  — user the action targets (e.g. whose inbox)
///   `reason`          — short reason string (e.g. `manual`)
///
/// `meta_kv` is an optional list of `name=value` pairs that get
/// appended to the JSON object (e.g. `format=jsonl`,
/// `bytes_exported=1234`). Values are serialised as JSON strings, so
/// callers don't have to worry about quoting or escaping. Pass
/// `&.{}` for the legacy shape so the signature stays backwards
/// compatible with existing call sites.
///
/// Best-effort: any I/O, allocation, or path-overflow failure is
/// logged at warn level and silently swallowed so the caller (e.g.
/// `purgeInboxPair`) keeps working in the no-DB fallback path.
pub fn appendAudit(
    actor: []const u8,
    actor_user_id: []const u8,
    action: []const u8,
    target_workspace: []const u8,
    target_user: []const u8,
    reason: []const u8,
    meta_kv: []const []const u8,
) void {
    var path_buf: [64]u8 = undefined;
    const path = todayAuditPath(&path_buf) catch {
        log.warn("audit: failed to build path", .{});
        return;
    };

    std.Io.Dir.cwd().createDirPath(zfinal.io_instance.io, model.audit_dir) catch |err| {
        log.warn("audit: createDirPath({s}) failed: {}", .{ model.audit_dir, err });
        return;
    };

    var file = std.Io.Dir.cwd().createFile(zfinal.io_instance.io, path, .{ .truncate = false }) catch |err| {
        log.warn("audit: createFile({s}) failed: {}", .{ path, err });
        return;
    };
    defer file.close(zfinal.io_instance.io);

    const stat = file.stat(zfinal.io_instance.io) catch |err| {
        log.warn("audit: stat({s}) failed: {}", .{ path, err });
        return;
    };

    var ts_buf: [32]u8 = undefined;
    const ts = nowRfc3339Utc(&ts_buf) catch {
        log.warn("audit: failed to format timestamp", .{});
        return;
    };

    // Render the meta_kv pairs into a scratch buffer so we can append
    // them to the base JSON object. We split each pair at the first
    // `=`; if the slice is missing one, the entry is silently
    // skipped so a malformed pair can never corrupt the audit line.
    var meta_buf: [1024]u8 = undefined;
    var meta_written: usize = 0;
    for (meta_kv) |kv| {
        if (meta_written + kv.len + 8 > meta_buf.len) break; // overflow guard
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const name = kv[0..eq];
        const value = kv[eq + 1 ..];
        if (name.len == 0) continue;
        const prefix: []const u8 = if (meta_written == 0) "," else ",";
        const written = std.fmt.bufPrint(
            meta_buf[meta_written..],
            "{s}\"{s}\":\"{s}\"",
            .{ prefix, name, value },
        ) catch break;
        meta_written += written.len;
    }

    var line_buf: [2048]u8 = undefined;
    const with_nl = std.fmt.bufPrint(
        &line_buf,
        "{{\"ts\":\"{s}\",\"actor\":\"{s}\",\"user_id\":\"{s}\",\"action\":\"{s}\"," ++
            "\"workspace_id\":\"{s}\",\"target_user_id\":\"{s}\",\"reason\":\"{s}\"{s}}}\n",
        .{ ts, actor, actor_user_id, action, target_workspace, target_user, reason, meta_buf[0..meta_written] },
    ) catch {
        log.warn("audit: line too long (actor={s} action={s})", .{ actor, action });
        return;
    };

    std.Io.File.writePositionalAll(file, zfinal.io_instance.io, with_nl, stat.size) catch |err| {
        log.warn("audit: writePositionalAll failed: {}", .{err});
        return;
    };
}

/// Test helper: read all lines from today's audit JSONL file.
/// Mirrors `readTailJsonl` but for the service audit log. Returns
/// an empty slice when the file is absent so the test starts from a
/// clean slate without needing a `clearAuditForTest` companion.
pub fn readTodayAuditLines(allocator: std.mem.Allocator) ![]const []u8 {
    var path_buf: [64]u8 = undefined;
    const path = todayAuditPath(&path_buf) catch return &[_][]u8{};
    var file = std.Io.Dir.cwd().openFile(zfinal.io_instance.io, path, .{}) catch return &[_][]u8{};
    defer file.close(zfinal.io_instance.io);
    const stat = file.stat(zfinal.io_instance.io) catch return &[_][]u8{};
    const size: usize = @intCast(stat.size);
    if (size == 0) return &[_][]u8{};
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(zfinal.io_instance.io, &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const m = rdr.interface.readSliceShort(buf[offset..]) catch break;
        if (m == 0) break;
        offset += m;
    }
    var out: std.ArrayList([]u8) = .empty;
    var it = std.mem.splitScalar(u8, buf[0..offset], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const dup = try allocator.dupe(u8, line);
        try out.append(allocator, dup);
    }
    return out.toOwnedSlice(allocator);
}

/// Sum of envelope byte sizes currently in the per-(workspace, user)
/// ring buffer. Cheap (single lock acquisition + linear walk over
/// up to `RingCap` entries); intended for clients deciding whether
/// to send a `?max_bytes=` query string on `/api/inbox/since` or to
/// fetch the raw ring via `/api/inbox/admin/export`. Returns 0 when
/// the ring is empty or the map has never been initialised (the
/// no-DB / pre-WS path).
pub fn ringApproxBytes(workspace_id: []const u8, user_id: []const u8) usize {
    var total: usize = 0;
    const allocator = globalMapAllocator();
    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_ring_mutex.unlock(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.getEntry(key)) |entry| {
                for (entry.value_ptr.items) |env| {
                    total += env.len;
                }
            }
        } else |_| {}
    }
    return total;
}

/// Read the `seq` field out of an envelope JSON string. Returns
/// null when the input is not a valid JSON object or is missing the
/// `seq` field. Uses the page allocator internally because we only
/// need the parsed value for the duration of the call.
fn parseEnvelopeSeq(envelope: []const u8) ?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, envelope, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const seq_val = obj.get("seq") orelse return null;
    return switch (seq_val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Collect every envelope in the ring buffer for
/// `(workspace_id, user_id)` with `seq > since_seq` along with the
/// current `latest_seq`. Allocates a new slice of `[]const u8`
/// (slices into the ring buffer) for the caller to free with
/// `allocator.free(envelopes)`. Safe to call when no manager has
/// been spawned (the no-DB / no-WS fallback path).
pub fn replaySnapshot(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, since_seq: u64) model.ReplaySnapshot {
    var out: std.ArrayList([]const u8) = .empty;
    var replayed: usize = 0;

    // Lock the ring, gather matching envelopes, then unlock before
    // calling `latestSeq` (which takes a different mutex) to avoid
    // holding two locks at once.
    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.getEntry(key)) |entry| {
                for (entry.value_ptr.items) |env| {
                    const env_seq = parseEnvelopeSeq(env) orelse continue;
                    if (env_seq > since_seq) {
                        out.append(allocator, env) catch continue;
                        replayed += 1;
                    }
                }
            }
        } else |_| {}
    }
    g_ring_mutex.unlock(zfinal.io_instance.io);

    // The `toOwnedSlice` succeeds for any list, even an empty one —
    // the returned slice is always allocator-owned so the caller's
    // `allocator.free` is well-defined. We don't propagate OOM here
    // because the HTTP/WS callers already render a "no events"
    // response when the slice is empty; treating OOM the same way
    // is fine.
    const envelopes = out.toOwnedSlice(allocator) catch &[_][]const u8{};
    return .{
        .envelopes = envelopes,
        .latest_seq = latestSeq(workspace_id, user_id),
        .replayed = replayed,
    };
}

/// Collect every envelope in the ring buffer for
/// `(workspace_id, user_id)` with `seq > since_seq`, parse each
/// envelope into a `std.json.Value`, and return the parsed values
/// along with the matching parsed wrappers so the caller can free
/// the per-envelope arenas. The returned `events` slice and
/// `holders` slice are both owned by the caller (free with
/// `allocator.free(events)` and `allocator.free(holders)` after
/// iterating `holders` and calling `deinit()` on each entry).
///
/// Envelopes that fail to parse (or are missing a usable `seq`
/// field) are silently skipped — reconnecting clients receive only
/// well-formed envelopes. Safe to call when no manager has been
/// spawned (the no-DB / no-WS fallback path); an empty snapshot is
/// returned in that case.
pub fn replaySnapshotParsed(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    user_id: []const u8,
    since_seq: u64,
) !model.ReplaySnapshotParsed {
    var events_list: std.ArrayList(std.json.Value) = .empty;
    var holders_list: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    var replayed: usize = 0;

    // Lock the ring, gather matching envelopes, then unlock before
    // calling `latestSeq` (which takes a different mutex) to avoid
    // holding two locks at once.
    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.getEntry(key)) |entry| {
                for (entry.value_ptr.items) |env| {
                    const env_seq = parseEnvelopeSeq(env) orelse continue;
                    if (env_seq <= since_seq) continue;
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        allocator,
                        env,
                        .{ .ignore_unknown_fields = true },
                    ) catch continue;
                    // Append to `holders` first so we can deinit on
                    // failure without leaking the per-envelope arena.
                    holders_list.append(allocator, parsed) catch {
                        parsed.deinit();
                        continue;
                    };
                    // If this fails we have to keep `events` and
                    // `holders` in lock-step so the caller's defer
                    // loop stays correct, so pop the holder we just
                    // appended and deinit its arena.
                    events_list.append(allocator, parsed.value) catch {
                        _ = holders_list.pop();
                        parsed.deinit();
                        continue;
                    };
                    replayed += 1;
                }
            }
        } else |_| {}
    }
    g_ring_mutex.unlock(zfinal.io_instance.io);

    // Same OOM tolerance as `replaySnapshot`: on failure, return
    // empty slices so the caller's `allocator.free` is well-defined.
    // We leak the partial lists in that rare path, mirroring the
    // existing helper's behaviour.
    const events = events_list.toOwnedSlice(allocator) catch &[_]std.json.Value{};
    const holders = holders_list.toOwnedSlice(allocator) catch &[_]std.json.Parsed(std.json.Value){};
    return .{
        .events = events,
        .holders = holders,
        .latest_seq = latestSeq(workspace_id, user_id),
        .replayed = replayed,
    };
}

/// Initialise `g_manager` exactly once with a stable allocator
/// (the page allocator). The previous design used the per-request
/// allocator, which made the manager's lists hold pointers from
/// the first request's arena and segfaulted when a later request
/// tried to `deinit` them with its own (different) allocator.
/// Using the page allocator sidesteps the mismatch; the page
/// allocator doesn't track individual frees, so leaked memory at
/// shutdown is bounded by `O(rooms × connections)`.
fn ensureManager() !void {
    if (g_manager != null) return;
    g_manager_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_manager_mutex.unlock(zfinal.io_instance.io);
    if (g_manager != null) return;
    g_manager = model.RoomManager.init(std.heap.page_allocator);
}

/// ── Redis Pub/Sub bridge ─────────────────────────────────────
///
/// When Redis is available (`REDIS_URL` env), `publishIssueEvent`
/// and `publishChatMessage` also publish the payload to Redis
/// channel `ws:<workspace_id>`. The publish side works through
/// `redis.publish` (zfinal.RedisClient supports PUBLISH).
///
/// The subscriber side is NOT implemented. zfinal.RedisClient exposes a
/// synchronous command API with no message-read primitive for Redis
/// pub/sub push mode, so a background subscriber loop cannot be built on
/// it today. Consequence: multi-instance WS fanout does not exist yet —
/// a deployment with multiple zserver instances behind a load balancer
/// must pin each client's WS connection to one instance, or accept that
/// WS events are only delivered on the instance that published them.
/// This is a documented constraint, not a silent gap: SELF_HOSTING notes
/// single-instance operation for realtime. Implement the subscriber by
/// wiring `ensureRedisSubscribed` into `handleRealtime` once zfinal
/// exposes a read/message API.

/// Publish `payload` to Redis channel `ws:<id>` if Redis is
/// available. Silently no-ops when no Redis client or when the
/// publish fails.
fn broadcastToRedis(workspace_id: []const u8, payload: []const u8) void {
    const channel = std.fmt.allocPrint(std.heap.page_allocator, "ws:{s}", .{workspace_id}) catch return;
    defer std.heap.page_allocator.free(channel);
    _ = redis.publish(channel, payload) catch {};
}

/// ── End Redis bridge ─────────────────────────────────────────

/// Publish a JSON-encoded inbox event to every client currently
/// connected to the given workspace and record it in the
/// per-(workspace, user) ring buffer so reconnecting clients can
/// recover missed events via `/api/inbox/since` (or a future
/// WebSocket replay flow).
///
/// The wire format is a flat JSON object: the caller passes a
/// fully-rendered JSON object for `payload` (typically
/// `{"type":"inbox_updated","inbox_id":"…","workspace_id":"…","user_id":"…","action":"…","count":N}`)
/// and the envelope prepends a `seq` field. `user_id` may be empty
/// when the event isn't addressed to a single user. `seq` is the
/// monotonically increasing per-(workspace, user) counter; if seq
/// allocation fails we still broadcast the payload unchanged so no
/// event is silently dropped.
///
/// The seq counter is bumped *before* the broadcast check so
/// callers without any live WebSocket connections still advance the
/// cursor — that way the no-DB fallback (and tests) can verify the
/// contract via `/api/inbox/since` alone. The ring buffer is updated
/// even when no manager exists so reconnecting clients can still
/// replay.
pub fn publishInbox(workspace_id: []const u8, user_id: []const u8, payload: []const u8) void {
    // Use page_allocator as a fallback when no manager has been
    // spawned yet — the seq map needs *some* allocator to back its
    // strings, but these are tiny and live for the process lifetime
    // so leaking them is acceptable for the no-DB / pre-WS path.
    const seq_allocator = if (g_manager) |*m| m.allocator else std.heap.page_allocator;
    const seq = nextSeq(seq_allocator, workspace_id, user_id);

    // Build the flat envelope by prepending `seq` to the payload.
    // The payload is expected to be a JSON object starting with `{`;
    // the envelope becomes `{"seq":N,<rest of payload>}` which
    // matches the spec'd wire format.
    const envelope_allocator = if (g_manager) |*m| m.allocator else std.heap.page_allocator;
    const envelope: ?[]u8 = blk: {
        if (seq == 0) break :blk null;
        if (payload.len == 0 or payload[0] != '{') break :blk null;
        const inner = payload[1..];
        const built = std.fmt.allocPrint(
            envelope_allocator,
            "{{\"seq\":{d},{s}",
            .{ seq, inner },
        ) catch break :blk null;
        break :blk built;
    };

    if (envelope) |env| {
        // Push to ring buffer first so a slow broadcast path can't
        // cause us to lose the event for reconnecting clients. The
        // buffer copy is independent of `env`, which we free after
        // broadcasting.
        pushEnvelope(workspace_id, user_id, env);
        if (g_manager) |*m| m.broadcast(workspace_id, env);
        envelope_allocator.free(env);
        return;
    }

    // No seq (alloc failure) — broadcast the payload unchanged so
    // the event still reaches any connected clients. The ring
    // buffer isn't updated because the seq field is missing.
    if (g_manager) |*m| m.broadcast(workspace_id, payload);
}

/// Latest seq number published for a (workspace, user) pair.
/// Returns 0 when no event has been published yet (or the counter
/// map has never been initialised), which is the contract
/// reconnecting clients check before calling `/api/inbox/since`.
/// Lock-free: the per-pair `std.atomic.Value(u64)` is read with
/// `acquire` ordering.
pub fn latestSeq(workspace_id: []const u8, user_id: []const u8) u64 {
    g_seq_mutex.lockUncancelable(zfinal.io_instance.io);
    defer g_seq_mutex.unlock(zfinal.io_instance.io);
    const map = if (g_seq_map) |*m| m else return 0;
    const allocator = if (g_manager) |*m| m.allocator else std.heap.page_allocator;
    const key = seqKeyAlloc(allocator, workspace_id, user_id) catch return 0;
    defer allocator.free(key);
    const entry = map.getEntry(key) orelse return 0;
    return entry.value_ptr.load(.acquire);
}

/// Broadcast a workspace-scoped event (issue mutations, autopilot
/// runs, etc.). Unlike `publishInbox`, there is no per-user seq
/// counter — issue events are ephemeral fan-out and don't need
/// replay-on-reconnect. The payload is forwarded verbatim to every
/// connected client in the workspace room. No-op when no manager
/// exists (the no-DB / no-WS smoke path). Caller is responsible
/// for ensuring `payload` is a well-formed JSON string.
pub fn publishIssueEvent(workspace_id: []const u8, payload: []const u8) void {
    if (g_manager) |*m| m.broadcast(workspace_id, payload);
    broadcastToRedis(workspace_id, payload);
}

/// Replay envelopes with `seq > since_seq` from the
/// per-(workspace, user) ring buffer to the given WebSocket
/// connection. Each stored envelope is forwarded as a text frame in
/// chronological order, then a final
/// `{type: "replay_complete", since_seq, latest_seq, replayed}`
/// marker tells the client it can resume the live stream. The
/// function is a no-op when `latest_seq <= since_seq` (nothing to
/// replay).
///
/// For the HTTP path, `listInboxSince` calls `replaySnapshot`
/// directly and renders the envelopes into the response body — this
/// WS-side function only needs the connection for `sendText`.
pub fn replaySince(workspace_id: []const u8, user_id: []const u8, since_seq: u64, conn: *model.Conn) void {
    const snapshot = replaySnapshot(conn.allocator, workspace_id, user_id, since_seq);
    defer conn.allocator.free(snapshot.envelopes);

    for (snapshot.envelopes) |env| {
        conn.sendText(env);
    }

    // Always emit the completion marker so callers can advance
    // their cursor even when the ring buffer is empty / truncated.
    const marker = std.fmt.allocPrint(
        conn.allocator,
        "{{\"type\":\"replay_complete\",\"since_seq\":{d},\"latest_seq\":{d},\"replayed\":{d}}}",
        .{ since_seq, snapshot.latest_seq, snapshot.replayed },
    ) catch return;
    defer conn.allocator.free(marker);
    conn.sendText(marker);
}

/// Streaming variant of `replaySince`. Iterates the
/// per-(workspace, user) ring buffer under `g_ring_mutex` and
/// copies *references* (shallow slice pointers, no deep copy) into
/// a temporary `std.ArrayList([]u8)`. The mutex is released before
/// any blocking I/O so concurrent publishers can't be blocked while
/// we stream to a slow socket. Each envelope is emitted via
/// `conn.sendText(env)` followed by a separate `sendText("\n")` so
/// partial output is visible to log tailers and downstream
/// consumers don't have to wait for the full replay.
///
/// `conn` is `anytype` so test stubs can supply a thin fake
/// connection with a `sendText` field/method without having to
/// mirror the full `Conn` struct layout. Production callers pass
/// `*Conn`.
///
/// `since_seq` is the caller's last-seen sequence number. Pass
/// `null` to request a full replay (treated as `since_seq = 0`).
/// The completion marker echoes the effective `since_seq` so the
/// caller can confirm the cursor the server used.
///
/// `max_bytes` caps the *total* number of bytes sent during the
/// replay (envelopes + newlines + the final marker). When `null`,
/// the default is 1 MiB. If adding the next envelope would exceed
/// the cap, the loop stops early and a `{type:"replay_truncated",
/// ...}` marker is emitted in place of the completion marker so
/// the caller can resume from `latest_seq` on the next reconnect.
/// The default 1 MiB is chosen to fit comfortably in a single TCP
/// write while still bounding the worst-case blast radius of a
/// slow / hostile client.
pub fn replaySinceStream(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    user_id: []const u8,
    since_seq: ?u64,
    conn: anytype,
    max_bytes: ?usize,
) !void {
    // Normalise the optional cursor to a concrete value. `null`
    // means "give me everything" — equivalent to `since_seq = 0`
    // for the filter (`env_seq > 0` is true for every stored
    // envelope).
    const effective_since: u64 = since_seq orelse 0;

    // 1 MiB default keeps a single replay under any sane TCP MSS
    // while still bounding the worst-case blast radius.
    const effective_max: usize = max_bytes orelse 1024 * 1024;

    var snapshot: std.ArrayList([]u8) = .empty;
    defer snapshot.deinit(allocator);

    g_ring_mutex.lockUncancelable(zfinal.io_instance.io);
    if (g_ring_map) |*map| {
        if (seqKeyAlloc(allocator, workspace_id, user_id)) |key| {
            defer allocator.free(key);
            if (map.getEntry(key)) |entry| {
                for (entry.value_ptr.items) |env| {
                    const env_seq = parseEnvelopeSeq(env) orelse continue;
                    if (env_seq > effective_since) {
                        snapshot.append(allocator, env) catch continue;
                    }
                }
            }
        } else |_| {}
    }
    // Snapshot is a list of slice references into the ring buffer;
    // the strings remain owned by the map and must NOT be freed
    // here.
    g_ring_mutex.unlock(zfinal.io_instance.io);

    const latest_seq = latestSeq(workspace_id, user_id);

    // Track how many bytes we've handed to `conn.sendText` so we
    // can stop early if the cap is exceeded. Each envelope
    // contributes `env.len + 1` (the trailing `\n`); the final
    // marker is counted at the end before we send it so we know
    // whether to emit `replay_complete` or `replay_truncated`.
    var sent_bytes: usize = 0;
    var replayed: usize = 0;
    var truncated: bool = false;

    for (snapshot.items) |env| {
        // Pre-flight the cap: refuse to write this envelope if it
        // would push us over the limit. We check `sent_bytes +
        // env.len + 1` so the trailing newline is also accounted
        // for.
        if (sent_bytes + env.len + 1 > effective_max) {
            truncated = true;
            break;
        }
        conn.sendText(env);
        conn.sendText("\n");
        sent_bytes += env.len + 1;
        replayed += 1;
    }

    if (truncated) {
        const marker = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"replay_truncated\",\"since_seq\":{d},\"latest_seq\":{d},\"replayed\":{d},\"sent_bytes\":{d},\"max_bytes\":{d}}}",
            .{ effective_since, latest_seq, replayed, sent_bytes, effective_max },
        );
        defer allocator.free(marker);
        conn.sendText(marker);
        conn.sendText("\n");
        return;
    }

    const marker = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"replay_complete\",\"since_seq\":{d},\"latest_seq\":{d},\"replayed\":{d}}}",
        .{ effective_since, latest_seq, replayed },
    );
    defer allocator.free(marker);
    conn.sendText(marker);
    conn.sendText("\n");
}

/// Publish a JSON-encoded chat message to every client currently
/// connected to the workspace that owns the chat session. The wire
/// format is `{type: "chat_message", payload}`. When no client is
/// connected, this is a silent no-op.
pub fn publishChatMessage(workspace_id: []const u8, session_id: []const u8, payload: []const u8) void {
    if (g_manager == null) return;
    const manager = &g_manager.?;
    const env = std.fmt.allocPrint(
        manager.allocator,
        "{{\"type\":\"chat_message\",\"session_id\":\"{s}\",\"payload\":{s}}}",
        .{ session_id, payload },
    ) catch return;
    defer manager.allocator.free(env);
    manager.broadcast(workspace_id, env);
    broadcastToRedis(workspace_id, env);
}

/// Total number of currently-tracked rooms. Exposed for the realtime
/// health endpoint and tests.
pub fn roomCount() usize {
    if (g_manager == null) return 0;
    const manager = &g_manager.?;
    manager.mutex.lockUncancelable(zfinal.io_instance.io);
    defer manager.mutex.unlock(zfinal.io_instance.io);
    return manager.rooms.count();
}

/// Total number of currently-connected clients. Exposed for the
/// realtime health endpoint and tests.
pub fn clientCount() usize {
    if (g_manager == null) return 0;
    const manager = &g_manager.?;
    manager.mutex.lockUncancelable(zfinal.io_instance.io);
    defer manager.mutex.unlock(zfinal.io_instance.io);
    var total: usize = 0;
    var it = manager.rooms.iterator();
    while (it.next()) |e| total += e.value_ptr.items.len;
    return total;
}

/// Snapshot of the manager's lifetime tick counters. Returns
/// `RoomManagerMetricsSnapshot{}` (all zeros) when no manager has
/// been initialised so the no-DB fallback path can pass the result
/// straight into `renderJson` without special-casing.
pub fn metrics() model.RoomManagerMetricsSnapshot {
    if (g_manager == null) return .{};
    const m = &g_manager.?;
    return .{
        .last_tick_at_ms = m.last_tick_at_ms.load(.acquire),
        .pruned_clients_total = m.pruned_clients_total.load(.acquire),
        .pruned_rooms_total = m.pruned_rooms_total.load(.acquire),
        .tick_count = m.tick_count.load(.acquire),
    };
}

fn getToken(ctx: *zfinal.Context) !?[]const u8 {
    const from_query = try ctx.getPara("token") orelse "";
    if (from_query.len > 0) return from_query;
    return try ctx.getCookie("multica_auth");
}

fn authenticate(ctx: *zfinal.Context) !?model.TokenInfo {
    const allocator = ctx.allocator;
    const token = try getToken(ctx) orelse return null;
    const tt = auth.detectTokenType(token);
    switch (tt) {
        .jwt => {
            const cfg = auth.getConfig() orelse return null;
            const info = auth.validateToken(ctx.allocator, cfg, token) catch return null;
            defer allocator.free(info.email);
            return model.TokenInfo{ .user_id = info.user_id };
        },
        else => {
            // Task, cloud-node and personal access tokens are
            // accepted as opaque valid tokens for the realtime
            // endpoint.
            return model.TokenInfo{ .user_id = null };
        },
    }
}

fn resolveWorkspace(ctx: *zfinal.Context) !?[]const u8 {
    const allocator = ctx.allocator;
    if (try ctx.getPara("workspace_id")) |id| {
        if (id.len > 0) return try allocator.dupe(u8, id);
    }
    if (try ctx.getPara("workspace_slug")) |slug| {
        if (slug.len > 0) {
            if (workspace.resolveSlug(allocator, slug)) |id| return id;
        }
    }
    return null;
}

fn publishMessage(conn: *model.Conn, message: []const u8) void {
    const client = redis.client() orelse {
        log.warn("redis unavailable; message dropped", .{});
        return;
    };
    const channel = std.fmt.allocPrint(conn.allocator, "mul:ws:{s}", .{conn.workspace_id}) catch return;
    defer conn.allocator.free(channel);
    _ = client.publish(channel, message) catch |err| {
        log.err("redis publish failed: {}", .{err});
    };
}

/// One decoded RESP frame: how many bytes it occupied, and — for pub/sub
/// `message` frames — the payload, which aliases the input buffer.
const RespFrame = struct {
    len: usize,
    payload: ?[]const u8 = null,
};

/// Hard cap on how much we will buffer for a single RESP frame (and on the
/// declared length of any `$<n>` bulk string). Two jobs:
///   * a peer streaming an unterminated frame can't grow `accum` forever;
///   * every `$<n>` header is range-checked *before* the `@intCast`, so the
///     `start + len + 2` arithmetic below can never wrap `usize`.
const max_pubsub_frame_bytes: usize = 4 * 1024 * 1024;

/// Upper bound on RESP array arity. Real pub/sub frames are 3 elements
/// (`message`/`subscribe`) or 4 (`pmessage`); anything larger is a
/// desynchronised stream, not a frame we should try to buffer.
const max_pubsub_array_len: i64 = 16;

/// Decode one non-array RESP value at `pos`, returning the offset just past
/// it. `out` receives the value's text. Returns null when `data` is
/// truncated mid-value (the caller should read more and retry).
fn respScalarEnd(data: []const u8, pos: usize, out: *[]const u8) !?usize {
    if (pos >= data.len) return null;
    const line_end = std.mem.indexOfPos(u8, data, pos, "\r\n") orelse {
        // Unterminated header line — only legal while it is still short.
        if (data.len - pos > max_pubsub_frame_bytes) return error.RespTooLarge;
        return null;
    };
    switch (data[pos]) {
        '+', '-', ':' => {
            out.* = data[pos + 1 .. line_end];
            return line_end + 2;
        },
        '$' => {
            const n = std.fmt.parseInt(i64, data[pos + 1 .. line_end], 10) catch return error.InvalidResp;
            if (n < 0) { // nil bulk string
                out.* = "";
                return line_end + 2;
            }
            // Range-check before narrowing: `@intCast` of a multi-exabyte
            // header used to produce a `start + len + 2` that overflowed.
            if (n > @as(i64, @intCast(max_pubsub_frame_bytes))) return error.RespTooLarge;
            const len: usize = @intCast(n);
            const start = line_end + 2;
            if (data.len < start + len + 2) return null;
            out.* = data[start .. start + len];
            return start + len + 2;
        },
        else => return error.InvalidResp,
    }
}

/// Decode the RESP frame at the start of `data`. Returns null when the frame
/// is not fully buffered yet. Pub/sub deliveries look like
/// `*3\r\n$7\r\nmessage\r\n$N\r\n<channel>\r\n$M\r\n<payload>\r\n`; anything
/// else (the subscribe ack, pongs) is consumed with a null payload.
fn parseRespFrame(data: []const u8) !?RespFrame {
    if (data.len == 0) return null;
    if (data[0] != '*') {
        var scratch: []const u8 = "";
        const end = try respScalarEnd(data, 0, &scratch) orelse return null;
        return RespFrame{ .len = end };
    }

    const line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
        if (data.len > max_pubsub_frame_bytes) return error.RespTooLarge;
        return null;
    };
    const count = std.fmt.parseInt(i64, data[1..line_end], 10) catch return error.InvalidResp;
    var pos = line_end + 2;
    if (count <= 0) return RespFrame{ .len = pos };
    if (count > max_pubsub_array_len) return error.RespTooLarge;

    var first: []const u8 = "";
    var last: []const u8 = "";
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        var elem: []const u8 = "";
        pos = try respScalarEnd(data, pos, &elem) orelse return null;
        if (i == 0) first = elem;
        last = elem;
    }

    return RespFrame{
        .len = pos,
        .payload = if (count >= 3 and std.mem.eql(u8, first, "message")) last else null,
    };
}

/// How long a single pub/sub read may block before the loop wakes up to
/// re-check `conn.closed`. This is what lets the WS thread shut the
/// subscriber down by *flagging* it rather than closing the socket out
/// from under an in-flight read (closed-fd / fd-reuse race).
const subscriber_poll_ms: u64 = 250;

/// Socket reader that bounds each underlying `net_read` with a wall-clock
/// timeout and performs exactly one syscall per `readVec`, so a caller gets
/// whatever bytes are available instead of blocking until the buffer is
/// full. (`std.Io.Reader.readSliceShort` only returns short at end of
/// stream — using it here made the subscriber wait for 4096 bytes that a
/// 60-byte pub/sub frame never delivers.)
///
/// Mirrors the `DeadlineReader` zfinal uses internally for RESP replies;
/// that one is private, hence the local copy.
const TimedReader = struct {
    io: std.Io,
    interface: std.Io.Reader,
    stream: std.Io.net.Stream,
    timeout_ms: u64,
    /// Real cause behind `error.ReadFailed` (notably `error.Timeout`).
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, timeout_ms: u64) TimedReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(r.timeout_ms)),
            .clock = .awake,
        } };

        const n = (r.io.operateTimeout(.{
            .net_read = .{
                .socket_handle = r.stream.socket.handle,
                .data = dest,
            },
        }, timeout) catch |err| {
            r.err = err;
            return error.ReadFailed;
        }).net_read catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// Read Redis pub/sub deliveries for this connection's workspace channel
/// and forward each payload to the WebSocket.
///
/// Lifetime contract with the WS thread (`handleRealtime`):
///   * the socket is *only* touched here; the WS thread signals shutdown
///     with `conn.close()` (which just sets `conn.closed`) and then joins,
///     so `rc.stream` is never closed while a read is in flight;
///   * `rc.deinit()` / `destroy(rc)` happen strictly after the join.
///
/// zfinal v0.20.9's RedisClient has no public pub/sub read path — its
/// `readResponse` is private and its `parseResp` collapses arrays to an
/// empty string — so frames are decoded off the client's stream here.
fn subscriberLoop(conn: *model.Conn) void {
    const rc = conn.redis_client orelse return;
    const allocator = rc.allocator;
    const channel = std.fmt.allocPrint(allocator, "mul:ws:{s}", .{conn.workspace_id}) catch return;
    defer allocator.free(channel);

    rc.subscribe(channel) catch |err| {
        log.err("redis subscribe failed for {s}: {}", .{ channel, err });
        return;
    };

    // Copy the socket handle up-front; if the client was already torn
    // down there is nothing to read and we must not touch it again.
    const stream = rc.stream orelse return;

    var read_buf: [4096]u8 = undefined;
    var tr = TimedReader.init(stream, zfinal.io_instance.io, &read_buf, subscriber_poll_ms);
    const r = &tr.interface;

    // Frames can straddle reads, so completed prefixes are drained out of
    // `accum` and the remainder is carried into the next iteration.
    var accum: std.ArrayList(u8) = .empty;
    defer accum.deinit(allocator);

    while (!conn.closed.load(.acquire)) {
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => break, // peer closed
            error.ReadFailed => {
                const cause = tr.err orelse error.ReadFailed;
                tr.err = null;
                // Poll tick — no data yet; loop to re-check `conn.closed`.
                if (cause == error.Timeout) continue;
                // A torn-down connection closes the fd; that read error is
                // expected, not worth logging.
                if (!conn.closed.load(.acquire)) {
                    log.err("redis subscriber read error: {}", .{cause});
                }
                break;
            },
        };

        const chunk = r.buffered();
        // A zero-byte fill is not end of stream.
        if (chunk.len == 0) continue;
        if (accum.items.len + chunk.len > max_pubsub_frame_bytes) {
            log.err("redis subscriber: frame exceeds {d} bytes; dropping subscription", .{max_pubsub_frame_bytes});
            break;
        }
        accum.appendSlice(allocator, chunk) catch break;
        r.toss(chunk.len);

        // Drain every frame that is fully buffered. `consumed` is trimmed
        // once at the end so a burst of frames costs a single memmove.
        var consumed: usize = 0;
        var fatal = false;
        while (true) {
            const frame = (parseRespFrame(accum.items[consumed..]) catch |err| {
                // The stream is desynchronised; there is no safe resync
                // point in RESP, so drop the subscription instead of
                // spinning on garbage.
                log.err("redis subscriber: bad RESP frame ({}); dropping subscription", .{err});
                fatal = true;
                break;
            }) orelse break;

            if (frame.payload) |payload| conn.sendText(payload);
            consumed += frame.len;
        }
        if (consumed > 0) {
            accum.replaceRange(allocator, 0, consumed, &.{}) catch {
                fatal = true;
            };
        }
        if (fatal) break;
    }
}

fn startSubscriber(allocator: std.mem.Allocator, conn: *model.Conn) !bool {
    const client = try redis.newConnection(allocator) orelse return false;
    conn.redis_client = client;
    conn.thread = std.Thread.spawn(.{}, subscriberLoop, .{conn}) catch |err| {
        // No subscriber thread means nobody will ever read this client;
        // release it rather than leaking the socket for the connection's
        // lifetime.
        conn.redis_client = null;
        client.deinit();
        allocator.destroy(client);
        return err;
    };
    return true;
}

pub fn handleRealtime(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    const upgrade = ctx.getHeader("upgrade") orelse "";
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_websocket_upgrade" });
        return;
    }

    const sec_key = ctx.getHeader("sec-websocket-key") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_sec_websocket_key" });
        return;
    };

    const workspace_id = try resolveWorkspace(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_required" });
        return;
    };
    defer allocator.free(workspace_id);

    const token_info = try authenticate(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return;
    };
    defer if (token_info.user_id) |uid| allocator.free(uid);

    try ensureManager();

    var ws = try ctx.req.respondWebSocket(.{ .key = sec_key });

    const conn = try allocator.create(model.Conn);
    conn.* = .{
        .allocator = allocator,
        .ws = &ws,
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .user_id = if (token_info.user_id) |uid| try allocator.dupe(u8, uid) else null,
    };
    errdefer {
        allocator.free(conn.workspace_id);
        if (conn.user_id) |uid| allocator.free(uid);
        allocator.destroy(conn);
    }

    try g_manager.?.add(conn.workspace_id, conn);
    errdefer g_manager.?.remove(conn);

    _ = try startSubscriber(allocator, conn);

    log.info("websocket connected workspace={s} user={?s}", .{ conn.workspace_id, conn.user_id });
    conn.sendText("{\"type\":\"connected\"}");

    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose,
            error.EndOfStream,
            => break,
            error.MessageOversize => {
                conn.sendText("{\"type\":\"error\",\"payload\":\"message_too_large\"}");
                continue;
            },
            else => break,
        };
        // Any successful frame counts as activity; bump heartbeat so
        // the RoomManager tick does not consider this connection
        // idle.
        conn.bumpHeartbeat();
        switch (msg.opcode) {
            .text, .binary => {
                const text = try allocator.dupe(u8, msg.data);
                defer allocator.free(text);
                publishMessage(conn, text);
            },
            .ping => conn.sendPong(msg.data),
            else => {},
        }
    }

    // Order matters: flag first, then join (the subscriber wakes within
    // `subscriber_poll_ms`), and only once it is gone may the Redis client
    // — and its socket — be released.
    conn.close();
    if (conn.thread) |t| t.join();
    g_manager.?.remove(conn);

    if (conn.redis_client) |rc| {
        rc.deinit();
        allocator.destroy(rc);
    }

    allocator.free(conn.workspace_id);
    if (conn.user_id) |uid| allocator.free(uid);
    allocator.destroy(conn);

    log.info("websocket disconnected workspace={s} user={?s}", .{ workspace_id, token_info.user_id });
}

// ── RESP pub/sub framing tests ───────────────────────────────────────

test "parseRespFrame: extracts payload from a message delivery" {
    const wire = "*3\r\n$7\r\nmessage\r\n$10\r\nmul:ws:abc\r\n$13\r\n{\"type\":\"x\"}!\r\n";
    const frame = (try parseRespFrame(wire)).?;
    try std.testing.expectEqual(wire.len, frame.len);
    try std.testing.expectEqualStrings("{\"type\":\"x\"}!", frame.payload.?);
}

test "parseRespFrame: subscribe ack is consumed with no payload" {
    const wire = "*3\r\n$9\r\nsubscribe\r\n$10\r\nmul:ws:abc\r\n:1\r\n";
    const frame = (try parseRespFrame(wire)).?;
    try std.testing.expectEqual(wire.len, frame.len);
    try std.testing.expect(frame.payload == null);
}

test "parseRespFrame: partial frames return null until complete" {
    const wire = "*3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$5\r\nhello\r\n";
    // Every truncation of a real frame must be "need more data", never a
    // bogus payload and never an error — this is the short-read contract
    // the subscriber loop relies on.
    var i: usize = 1;
    while (i < wire.len) : (i += 1) {
        try std.testing.expect((try parseRespFrame(wire[0..i])) == null);
    }
    const frame = (try parseRespFrame(wire)).?;
    try std.testing.expectEqualStrings("hello", frame.payload.?);
}

test "parseRespFrame: back-to-back frames are drained one at a time" {
    const one = "*3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$1\r\na\r\n";
    const two = "*3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$1\r\nb\r\n";
    const wire = one ++ two;

    const first = (try parseRespFrame(wire)).?;
    try std.testing.expectEqual(one.len, first.len);
    try std.testing.expectEqualStrings("a", first.payload.?);

    const second = (try parseRespFrame(wire[first.len..])).?;
    try std.testing.expectEqual(two.len, second.len);
    try std.testing.expectEqualStrings("b", second.payload.?);
}

test "parseRespFrame: absurd bulk length is rejected, not overflowed" {
    // `@intCast`-ing this straight to usize and computing `start + len + 2`
    // wrapped around and tripped the overflow panic.
    try std.testing.expectError(
        error.RespTooLarge,
        parseRespFrame("*3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$9223372036854775807\r\n"),
    );
    try std.testing.expectError(
        error.InvalidResp,
        parseRespFrame("*3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$99999999999999999999\r\n"),
    );
    try std.testing.expectError(
        error.RespTooLarge,
        parseRespFrame("*99\r\n"),
    );
}
