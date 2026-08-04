//! Auth module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and any escape-hatch SQL helpers. `service.zig`
//! wraps this with the business logic.
//!
//! `User` and `VerificationCode` are structs (not `zfinal.Model`
//! instances) because their tables use UUID PKs and JSONB-ish fields
//! (`expires_at` via `interval`, `used` boolean, `attempts` counter)
//! that the ORM can't model. All SQL goes through `zfinal.SqlParam`
//! via `deps.acquire()`.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

/// `user` row.
pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
};

/// `verification_code` row.
pub const VerificationCode = struct {
    id: []const u8,
    email: []const u8,
    code: []const u8,
    used: bool,
};

/// `SELECT 1 FROM "user" WHERE email = $1` — returns `true` if a
/// user with that email already exists.
pub fn userExistsByEmail(email: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        \\SELECT 1 FROM "user" WHERE email = $1
    , &[_]SqlParam{.{ .text = email }}) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `INSERT INTO verification_code (...)` — stores a freshly issued
/// login code. Best-effort: failures are logged and ignored so the
/// no-DB / soft-failure paths still work.
pub fn insertVerificationCode(email: []const u8, code: []const u8) void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        \\INSERT INTO verification_code (email, code, expires_at, used, attempts)
        \\VALUES ($1, $2, now() + interval '10 minutes', false, 0)
    , &[_]SqlParam{
        .{ .text = email },
        .{ .text = code },
    }) catch {};
}

/// Best-effort `DELETE FROM verification_code WHERE expires_at < now()`.
pub fn purgeExpiredCodes() void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        "DELETE FROM verification_code WHERE expires_at < now()",
        &[_]SqlParam{},
    ) catch {};
}

/// Fetch the most-recent, unexpired, unused code for `email`. Returns
/// `null` if none exists. The caller is responsible for parsing
/// `code` (the stored code string) and `expires_at` (ISO timestamp).
pub fn latestActiveCodeRow(email: []const u8) ?struct { id: []const u8, code: []const u8 } {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        \\SELECT id::text, code FROM verification_code
        \\WHERE email = $1 AND used = false AND expires_at > now()
        \\ORDER BY created_at DESC LIMIT 1
    , &[_]SqlParam{.{ .text = email }}) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    // Duplicate the strings: the result set is freed at the end of
    // this function (defer rs.deinit), so returning raw pointers
    // from the result set would be a use-after-free.
    const allocator = db.allocator;
    const id = allocator.dupe(u8, rs.rows.items[0].getText(0) orelse return null) catch return null;
    const code = allocator.dupe(u8, rs.rows.items[0].getText(1) orelse return null) catch {
        allocator.free(id);
        return null;
    };
    return .{ .id = id, .code = code };
}

/// Bump the attempt counter on a row.
pub fn incrementCodeAttempts(id: []const u8) void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        "UPDATE verification_code SET attempts = attempts + 1 WHERE id = $1",
        &[_]SqlParam{.{ .text = id }},
    ) catch {};
}

/// Mark a code as used.
pub fn markCodeUsed(id: []const u8) !void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    try db.execParams(
        "UPDATE verification_code SET used = true WHERE id = $1",
        &[_]SqlParam{.{ .text = id }},
    );
}

/// Upsert a user and return the row's id. The `name` falls back to
/// the local-part of the email when the caller doesn't have one.
pub fn upsertUserByEmail(email: []const u8, name: []const u8) ![]const u8 {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        \\INSERT INTO "user" (id, name, email, created_at, updated_at)
        \\VALUES (gen_random_uuid(), $1, $2, now(), now())
        \\ON CONFLICT (email) DO UPDATE SET updated_at = now() RETURNING id::text
    , &[_]SqlParam{
        .{ .text = name },
        .{ .text = email },
    });
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.UpsertFailed;
    return db.allocator.dupe(u8, rs.rows.items[0].getText(0) orelse return error.UpsertFailed) catch error.UpsertFailed;
}
