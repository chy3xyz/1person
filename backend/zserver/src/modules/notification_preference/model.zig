//! Notification preference module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and any escape-hatch SQL helpers. `service.zig`
//! wraps this with the business logic. The legacy handler had the
//! `preferences` JSONB row straddling helper functions and the global
//! state; the split here puts the JSON helpers + DB read/write here
//! and the in-memory `default_prefs` value in `service.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// The `notification_preference.preferences` JSONB blob, in the shape
/// the API returns to clients.
pub const PreferencesResponse = struct {
    email_digest: bool,
    email_mentions: bool,
    email_task_updates: bool,
    push_mentions: bool,
    push_task_updates: bool,
};

/// The request body for `PUT /api/notification-preferences`.
pub const PreferencesRequest = struct {
    email_digest: ?bool = null,
    email_mentions: ?bool = null,
    email_task_updates: ?bool = null,
    push_mentions: ?bool = null,
    push_task_updates: ?bool = null,
};

/// Default values used when no per-user row exists in the database.
pub const default_prefs = PreferencesResponse{
    .email_digest = true,
    .email_mentions = true,
    .email_task_updates = true,
    .push_mentions = true,
    .push_task_updates = true,
};

/// Render the response as the JSON object that lives inside the `preferences`
/// JSONB column.
pub fn encodePrefsJson(allocator: std.mem.Allocator, prefs: PreferencesResponse) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"email_digest":{s},"email_mentions":{s},"email_task_updates":{s},"push_mentions":{s},"push_task_updates":{s}}}
    ,
        .{
            if (prefs.email_digest) "true" else "false",
            if (prefs.email_mentions) "true" else "false",
            if (prefs.email_task_updates) "true" else "false",
            if (prefs.push_mentions) "true" else "false",
            if (prefs.push_task_updates) "true" else "false",
        },
    );
}

pub fn parsePrefsJson(allocator: std.mem.Allocator, text: []const u8) !PreferencesResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return default_prefs;
    defer parsed.deinit();
    var out = default_prefs;
    switch (parsed.value) {
        .object => |obj| {
            if (obj.get("email_digest")) |v| {
                if (v == .bool) out.email_digest = v.bool;
            }
            if (obj.get("email_mentions")) |v| {
                if (v == .bool) out.email_mentions = v.bool;
            }
            if (obj.get("email_task_updates")) |v| {
                if (v == .bool) out.email_task_updates = v.bool;
            }
            if (obj.get("push_mentions")) |v| {
                if (v == .bool) out.push_mentions = v.bool;
            }
            if (obj.get("push_task_updates")) |v| {
                if (v == .bool) out.push_task_updates = v.bool;
            }
        },
        else => {},
    }
    return out;
}

/// Read the per-user preference row from the database. Returns `null`
/// when the database is unconfigured OR when the row does not exist.
pub fn readFromDb(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8) !?PreferencesResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT preferences::text FROM notification_preference " ++
            "WHERE workspace_id = $1::uuid AND user_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse "{}";
    return try parsePrefsJson(allocator, text);
}

/// Upsert the per-user preference row into the database. No-op when
/// the database is unconfigured.
pub fn writeToDb(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, prefs: PreferencesResponse) !void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    const json = try encodePrefsJson(allocator, prefs);
    defer allocator.free(json);
    try db.execParams(
        "INSERT INTO notification_preference (workspace_id, user_id, preferences, updated_at) " ++
            "VALUES ($1::uuid, $2::uuid, $3::jsonb, now()) " ++
            "ON CONFLICT (workspace_id, user_id) DO UPDATE SET preferences = EXCLUDED.preferences, updated_at = now()",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
            .{ .text = json },
        },
    );
}