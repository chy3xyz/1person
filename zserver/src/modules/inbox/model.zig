//! Inbox module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response) and the escape-hatch SQL
//! helpers. `service.zig` wraps this with the business logic and the
//! in-memory fallback for the no-DB smoke path.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const realtime = @import("../../modules/realtime/service.zig");

const log = std.log.scoped(.inbox_model);

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised. Callers own the
/// `defer deps.releaseBack(db)`.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

// ──────────────────────────────────────────────────────────────────────
// in-memory entry struct
// ──────────────────────────────────────────────────────────────────────

/// In-memory `inbox_item` row.
pub const InboxEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    recipient_type: []const u8,
    recipient_id: []const u8,
    type: []const u8,
    severity: []const u8,
    issue_id: []const u8,
    title: []const u8,
    body: []const u8,
    read: bool,
    archived: bool,
    created_at: []const u8,
    issue_status: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    details: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// response DTO
// ──────────────────────────────────────────────────────────────────────

/// `inbox_item` row, projected for the API.
pub const InboxResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    recipient_type: []const u8,
    recipient_id: []const u8,
    type: []const u8,
    severity: []const u8,
    issue_id: ?[]const u8,
    title: []const u8,
    body: ?[]const u8,
    read: bool,
    archived: bool,
    created_at: []const u8,
    issue_status: ?[]const u8,
    actor_type: ?[]const u8,
    actor_id: ?[]const u8,
    details: ?std.json.Value,
};

// ──────────────────────────────────────────────────────────────────────
// row → response converters
// ──────────────────────────────────────────────────────────────────────

/// Parse a JSON text blob into a `std.json.Value`. The caller owns
/// the `holder` (a `?std.json.Parsed(std.json.Value)`) — the parsed
/// value's lifetime is tied to the `holder`'s arena, so the holder
/// must outlive any `renderJson` call that uses the returned
/// `std.json.Value`.
pub fn parseDetails(allocator: std.mem.Allocator, text: []const u8, holder: *?std.json.Parsed(std.json.Value)) !?std.json.Value {
    if (text.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    holder.* = parsed;
    return parsed.value;
}

/// Convert an in-memory `InboxEntry` to the API response shape.
pub fn inboxResponseFromEntry(allocator: std.mem.Allocator, entry: InboxEntry, holder: *?std.json.Parsed(std.json.Value)) !InboxResponse {
    return InboxResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .recipient_type = entry.recipient_type,
        .recipient_id = entry.recipient_id,
        .type = entry.type,
        .severity = entry.severity,
        .issue_id = if (entry.issue_id.len > 0) entry.issue_id else null,
        .title = entry.title,
        .body = if (entry.body.len > 0) entry.body else null,
        .read = entry.read,
        .archived = entry.archived,
        .created_at = entry.created_at,
        .issue_status = if (entry.issue_status.len > 0) entry.issue_status else null,
        .actor_type = if (entry.actor_type.len > 0) entry.actor_type else null,
        .actor_id = if (entry.actor_id.len > 0) entry.actor_id else null,
        .details = try parseDetails(allocator, entry.details, holder),
    };
}

/// Convert a `SELECT id, workspace_id, recipient_type, recipient_id,
/// type, severity, issue_id, title, body, read, archived, created_at,
/// issue_status, actor_type, actor_id, details FROM inbox_item` row to
/// the API response shape.
pub fn inboxResponseFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize, holder: *?std.json.Parsed(std.json.Value)) !InboxResponse {
    const r = &rs.rows.items[row];
    const details = r.getText(15) orelse "";
    const read_text = r.getText(9) orelse "";
    const archived_text = r.getText(10) orelse "";
    const isTrue = struct {
        fn check(t: []const u8) bool {
            return std.mem.eql(u8, t, "t") or
                std.mem.eql(u8, t, "true") or
                std.mem.eql(u8, t, "1");
        }
    }.check;
    return InboxResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .recipient_type = r.getText(2) orelse "",
        .recipient_id = r.getText(3) orelse "",
        .type = r.getText(4) orelse "",
        .severity = r.getText(5) orelse "",
        .issue_id = r.getText(6),
        .title = r.getText(7) orelse "",
        .body = r.getText(8),
        .read = isTrue(read_text),
        .archived = isTrue(archived_text),
        .created_at = r.getText(11) orelse "",
        .issue_status = r.getText(12),
        .actor_type = r.getText(13),
        .actor_id = r.getText(14),
        .details = try parseDetails(allocator, details, holder),
    };
}

// ──────────────────────────────────────────────────────────────────────
// misc helpers
// ──────────────────────────────────────────────────────────────────────

/// Generate a stable pseudo-UUID for the in-memory store. Mirrors the
/// algorithm used by the legacy `src/handlers/inbox.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

/// Build a JSON payload describing an inbox event and dispatch it through
/// the realtime broadcaster. Best-effort: callers run this after a
/// successful write and treat it as fire-and-forget. The allocator is
/// expected to be `ctx.allocator`; ownership of the formatted payload stays
/// with `publishInbox` (it copies before returning), so the caller does not
/// need to free it.
pub fn notifyInboxChange(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    user_id: []const u8,
    inbox_id: []const u8,
    action: []const u8,
    count: usize,
) void {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"inbox_updated\",\"inbox_id\":\"{s}\",\"workspace_id\":\"{s}\",\"user_id\":\"{s}\",\"action\":\"{s}\",\"count\":{d}}}",
        .{ inbox_id, workspace_id, user_id, action, count },
    ) catch return;
    defer allocator.free(payload);
    realtime.publishInbox(workspace_id, user_id, payload);
}

/// Serialise a single parsed event into a temporary buffer and return
/// the resulting byte count. The buffer is freed before return so the
/// heap stays clean. Used both for the un-truncated measurement path
/// and for incremental `?max_bytes=` accounting.
pub fn measureParsedEvent(allocator: std.mem.Allocator, event: std.json.Value) !usize {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(event, .{}, &buf.writer);
    return buf.written().len;
}
