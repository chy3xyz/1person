//! Webhook module — data layer.
//!
//! In-memory only: every webhook endpoint records the most recent
//! payload (up to 100) into `service.mem_payloads` when no DB is
//! available. The DB path is handled inline in `service.zig` because
//! the per-source `X-Hub-Signature-256` / `Stripe-Signature` flow is
//! per-handler, not a generic helper.

const std = @import("std");

/// A single webhook payload, kept in `service.mem_payloads` for
/// inspection in no-DB mode. `signature_valid` is `true` only when a
/// secret was configured AND the signature header verified.
pub const WebhookPayloadEntry = struct {
    id: []const u8,
    source: []const u8,
    received_at: []const u8,
    signature_valid: bool,
    payload: []const u8,
};

/// Stable pseudo-UUID for the in-memory store. Mirrors the algorithm
/// used by the legacy `src/handlers/webhook.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const zfinal = @import("zfinal");
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
