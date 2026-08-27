//! Personal access token module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.

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

/// In-memory `personal_access_token` row.
pub const PatEntry = struct {
    id: []const u8,
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
    token_hash: []const u8,
    token_prefix: []const u8,
    expires_at: ?i64,
    last_used_at: ?i64,
    created_at: i64,
    revoked: bool,
};

/// API response shape for `GET /api/tokens`.
pub const PatResponse = struct {
    id: []const u8,
    name: []const u8,
    token_prefix: []const u8,
    expires_at: ?[]const u8,
    last_used_at: ?[]const u8,
    created_at: []const u8,
};

/// Request body for `POST /api/tokens`.
pub const CreatePatRequest = struct {
    name: []const u8,
    expires_in_days: ?i32 = null,
};

/// Response body for `POST /api/tokens` — the only response that
/// returns the raw token once.
pub const CreatePatResponse = struct {
    id: []const u8,
    name: []const u8,
    token_prefix: []const u8,
    expires_at: ?[]const u8,
    last_used_at: ?[]const u8,
    created_at: []const u8,
    token: []const u8,
};

/// Response body for `POST /api/tokens/current/renew`.
pub const RenewPatResponse = struct {
    expires_at: []const u8,
    renewed: bool,
};

/// Resolved caller identity — user id + email.
pub const CurrentUser = struct {
    id: []const u8,
    email: []const u8,
};

/// Format an epoch-seconds timestamp as RFC3339 (`YYYY-MM-DDTHH:MM:SSZ`).
pub fn rfc3339(allocator: std.mem.Allocator, ts: i64) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sd = epoch.getDaySeconds();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        sd.getHoursIntoDay(), sd.getMinutesIntoHour(), sd.getSecondsIntoMinute(),
    });
}

/// Render an optional epoch-seconds timestamp as an optional RFC3339
/// string. Returns `null` when `ts` is `null`.
pub fn optionalTimestamp(allocator: std.mem.Allocator, ts: ?i64) !?[]const u8 {
    const t = ts orelse return null;
    return try rfc3339(allocator, t);
}

/// Parse a bool cell that comes back as text from `zfinal.DB`.
/// Returns `def` when the cell is NULL or unrecognised.
pub fn parseBool(text: ?[]const u8, def: bool) bool {
    const t = text orelse return def;
    if (std.mem.eql(u8, t, "t") or std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) return true;
    return false;
}