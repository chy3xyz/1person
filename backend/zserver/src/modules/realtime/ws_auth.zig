//! WebSocket handshake authentication for the realtime module.
//!
//! The realtime endpoint has two ways to prove who the caller is, and the
//! order matters:
//!
//!   1. **Before the upgrade** — an HttpOnly session cookie, or a `?token=`
//!      query parameter. Both are visible to the HTTP layer, so the
//!      handshake can be rejected with a plain status code.
//!   2. **After the upgrade** — the first text frame carries the token:
//!      `{"type":"auth","payload":{"token":"..."}}`. This is the only
//!      option for native clients (React Native has no cookie jar), and it
//!      is the shape every shipped client already sends.
//!
//! The second path is why the upgrade itself must not require a token:
//! rejecting an unauthenticated upgrade would lock native clients out
//! before they ever get a chance to send their auth frame.
//!
//! Two rules hold for both paths:
//!
//!   * A token that resolves to no user identity is **rejected**. An
//!     unauthenticated socket must never join a workspace room.
//!   * The resolved user must be a **member** of the workspace. Without
//!     this check any holder of a valid token could subscribe to any
//!     workspace's events by guessing its slug.
//!
//! The wire shapes mirror the upstream Go server: `auth_ack` on success,
//! and `{"error":"..."}` frames (not HTTP statuses — the socket is already
//! upgraded) on failure.

const std = @import("std");
const zfinal = @import("zfinal");
const auth = @import("../../auth.zig");
const deps = @import("../../deps.zig");

const log = std.log.scoped(.realtime_auth);

/// Result of a membership lookup.
pub const Membership = enum {
    /// The user is a member of the workspace.
    member,
    /// The user is not a member of the workspace.
    not_member,
    /// The database was unreachable — the caller must fail closed.
    db_error,
    /// No database is configured at all (dev / no-DB smoke path).
    no_db,
};

/// Parse `{"type":"auth","payload":{"token":"..."}}`.
///
/// Returns the token, or null when the frame is not a well-formed auth
/// frame. The caller owns the returned slice.
pub fn parseAuthFrame(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const AuthFrame = struct {
        type: []const u8,
        payload: ?struct {
            token: []const u8,
        },
    };

    const parsed = std.json.parseFromSlice(AuthFrame, allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.type, "auth")) return null;
    const payload = parsed.value.payload orelse return null;
    if (payload.token.len == 0) return null;
    return try allocator.dupe(u8, payload.token);
}

/// Resolve the user id bound to a token.
///
/// Returns null when the token is invalid or carries no user identity.
/// The returned slice is `allocator`-owned.
///
/// Only the two token kinds that represent a *person* are accepted: the
/// session JWT and a personal access token. Task (`1t_`), cloud-node
/// (`1c_`) and daemon (`1d_`) tokens have their own channels — the daemon
/// talks to `/api/daemon/ws`, and a task token is bound to a single task
/// rather than to a workspace session — so they are refused here instead
/// of being admitted with an empty identity.
pub fn resolveUserId(allocator: std.mem.Allocator, token: []const u8) !?[]const u8 {
    switch (auth.detectTokenType(token)) {
        .jwt => {
            const cfg = auth.getConfig() orelse return null;
            const info = auth.validateToken(allocator, cfg, token) catch return null;
            defer allocator.free(info.email);
            return try allocator.dupe(u8, info.user_id);
        },
        .personal => {
            if (!deps.hasPool()) return null;
            const hash = try auth.hashToken(allocator, token);
            defer allocator.free(hash);

            const db = deps.acquire() catch {
                log.err("DB acquire failed during personal-token verification", .{});
                return error.DatabaseUnavailable;
            };
            defer deps.releaseBack(db);

            var rs = try db.queryParams(
                "SELECT user_id::text FROM personal_access_token " ++
                    "WHERE token_hash = $1 AND revoked = false AND (expires_at IS NULL OR expires_at > now())",
                &[_]zfinal.SqlParam{.{ .text = hash }},
            );
            defer rs.deinit();
            if (rs.rows.items.len == 0) return null;
            const user_id = rs.rows.items[0].getText(0) orelse return null;
            return try allocator.dupe(u8, user_id);
        },
        .task, .cloud_node, .daemon => return null,
    }
}

/// Check that `user_id` is a member of `workspace_id`.
pub fn checkMembership(workspace_id: []const u8, user_id: []const u8) !Membership {
    if (!deps.hasPool()) return .no_db;

    const db = deps.acquire() catch {
        log.err("DB acquire failed during realtime membership check", .{});
        return .db_error;
    };
    defer deps.releaseBack(db);

    var rs = try db.queryParams(
        "SELECT 1 FROM member WHERE workspace_id = $1 AND user_id = $2",
        &[_]zfinal.SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return .not_member;
    return .member;
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseAuthFrame: reads the token out of a well-formed auth frame" {
    const allocator = testing.allocator;
    const token = try parseAuthFrame(
        allocator,
        \\{"type":"auth","payload":{"token":"jwt-value"}}
    );
    try testing.expectEqualStrings("jwt-value", token.?);
    allocator.free(token.?);
}

test "parseAuthFrame: rejects a frame that is not an auth frame" {
    const allocator = testing.allocator;
    try testing.expectEqual(@as(?[]const u8, null), try parseAuthFrame(allocator, "{\"type\":\"ping\"}"));
    try testing.expectEqual(@as(?[]const u8, null), try parseAuthFrame(allocator, "{\"type\":\"auth\"}"));
    try testing.expectEqual(@as(?[]const u8, null), try parseAuthFrame(allocator, "{\"type\":\"auth\",\"payload\":{}}"));
    try testing.expectEqual(@as(?[]const u8, null), try parseAuthFrame(allocator, "not json"));
    try testing.expectEqual(@as(?[]const u8, null), try parseAuthFrame(allocator, ""));
}

test "parseAuthFrame: ignores unknown fields around the auth payload" {
    const allocator = testing.allocator;
    const token = try parseAuthFrame(
        allocator,
        \\{"type":"auth","payload":{"token":"t","extra":1},"trace":"x"}
    );
    try testing.expectEqualStrings("t", token.?);
    allocator.free(token.?);
}

test "resolveUserId: refuses a token that carries no user identity" {
    const allocator = testing.allocator;
    // A task token has a valid shape but no user session behind it on the
    // realtime endpoint.
    try testing.expectEqual(@as(?[]const u8, null), try resolveUserId(allocator, "1t_whatever"));
    try testing.expectEqual(@as(?[]const u8, null), try resolveUserId(allocator, "1d_whatever"));
    try testing.expectEqual(@as(?[]const u8, null), try resolveUserId(allocator, "1c_whatever"));
}

test "resolveUserId: refuses a malformed JWT" {
    const allocator = testing.allocator;
    try testing.expectEqual(@as(?[]const u8, null), try resolveUserId(allocator, "not-a-jwt"));
    try testing.expectEqual(@as(?[]const u8, null), try resolveUserId(allocator, "a.b.c"));
}
