//! Contact module — data layer.
//!
//! In-memory only: there is no `contact_sales_inquiry` SQL helper here
//! because the DB write happens inline in `service.zig` (the legacy
//! `src/handlers/contact.zig` did the same — the table layout is owned
//! by the handler, not abstracted behind a helper). When no DB is
//! available submissions are appended to an in-memory list so smoke
//! tests can still verify the path.

const std = @import("std");

/// A single contact-sales submission, kept in `service.mem_submissions`
/// for inspection in no-DB mode. `created_at` is an RFC-3339 string.
pub const ContactEntry = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    company: ?[]const u8,
    message: []const u8,
    created_at: []const u8,
};

/// Request body for `POST /api/contact-sales`. All fields are optional
/// so the service can return a single, consistent 400 with a list of
/// the missing ones rather than per-field validation.
pub const ContactSalesRequest = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    company: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Stable pseudo-UUID for the in-memory store. Mirrors the algorithm
/// used by the legacy `src/handlers/contact.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const zfinal = @import("zfinal");
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

/// Render the current Unix-epoch seconds as an RFC-3339 UTC string.
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
