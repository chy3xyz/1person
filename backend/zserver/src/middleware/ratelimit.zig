//! Fixed-window rate limiting interceptor. Redis-backed when Redis is
//! configured; falls back to an in-process fixed-window limiter when it
//! is not, so rate limits are always enforced (per-instance rather than
//! shared across instances without Redis).
//!
//! Multi-instance deployments should set REDIS_URL so limits are shared;
//! the in-memory fallback is a fail-closed convenience, not a substitute
//! for shared state.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../config.zig").Config;
const redis = @import("../redis.zig");

const log = std.log.scoped(.ratelimit);

var g_cfg: ?*const Config = null;

pub fn setConfig(cfg: *const Config) void {
    g_cfg = cfg;
}

const LimitConfig = struct {
    max: u32,
    window: u32,
};

var g_fallback: LimitConfig = .{ .max = 100, .window = 60 };

// ── In-memory fallback state ─────────────────────────────────────────
// Bounded map of per-(path,ip) fixed windows. Keys are owned by the map
// (StringHashMap copies into its allocator). Entries older than the
// active window are pruned once the table exceeds the cap, so memory is
// bounded even under IP churn. page_allocator is used so the map never
// holds per-request arenas; whatever is live at shutdown is a bounded
// leak by design.
const FallbackEntry = struct {
    key: []const u8 = "",
    count: u32 = 0,
    window_start_ms: i64 = 0,
};

const MEMORY_FALLBACK_MAX_KEYS: usize = 4096;

var g_fallback_mutex: std.Io.Mutex = .init;
// Fixed-size open table. A StringHashMap grown concurrently corrupts its
// buckets (putAssumeCapacityNoClobber assertions under parallel request
// load), so the fallback uses a flat array with linear probing inside the
// mutex. 4096 entries with an occasional O(n) prune is fine for a rate
// limiter.
//
// The table is left `undefined`: a slot's key length is only read for slots
// below the high-water mark, and those were all written by this code. Slots
// at or past the mark were never used and are free.
var g_fallback_table: [MEMORY_FALLBACK_MAX_KEYS]FallbackEntry = undefined;
/// High-water mark: how many slots have ever been written. Slots at or past
/// it were never used and are free.
var g_fallback_count: usize = 0;

/// Core of the in-memory limiter, over an explicit table so it can be
/// exercised without a request context.
///
/// Returns true when the request is allowed. The table is scanned linearly:
/// a matching entry counts the hit, an entry whose window rolled over is
/// reclaimed, and the first free slot takes a new key.
fn memoryAllow(
    slots: []FallbackEntry,
    count: *usize,
    key: []const u8,
    now_ms: i64,
    window_ms: i64,
    max: u32,
) !bool {
    var free_slot: ?usize = null;
    var entry: ?*FallbackEntry = null;
    for (slots, 0..) |*slot, i| {
        if (i >= count.*) {
            // Past the high-water mark the slot was never written, so it is
            // free — and so is every slot after it.
            if (free_slot == null) free_slot = i;
            break;
        }
        if (slot.key.len == 0) {
            if (free_slot == null) free_slot = i;
            continue;
        }
        if (now_ms - slot.window_start_ms >= window_ms) {
            // Expired — reclaim the slot. The key lives in the page
            // allocator so it can be released here; the request arena that
            // produced it is long gone.
            std.heap.page_allocator.free(slot.key);
            slot.* = .{};
            if (free_slot == null) free_slot = i;
            continue;
        }
        if (std.mem.eql(u8, slot.key, key)) {
            entry = slot;
            break;
        }
    }

    if (entry) |e| {
        e.count += 1;
        return e.count <= max;
    }

    if (free_slot) |idx| {
        slots[idx] = .{
            .key = try std.heap.page_allocator.dupe(u8, key),
            .count = 1,
            .window_start_ms = now_ms,
        };
        if (idx >= count.*) count.* = idx + 1;
        return true;
    }

    // Table full — fail open (allow) rather than crash. This is the signal
    // that the limiter has stopped enforcing anything, so say so loudly.
    log.warn("rate limit fallback table full; allowing request", .{});
    return true;
}

fn checkRateLimitMemory(ctx: *zfinal.Context, max: u32, window_seconds: u32) !bool {
    const key = try rateLimitKey(ctx);
    defer ctx.allocator.free(key);

    const now_ms = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
    const window_ms: i64 = @as(i64, window_seconds) * 1000;

    try g_fallback_mutex.lock(zfinal.io_instance.io);
    defer g_fallback_mutex.unlock(zfinal.io_instance.io);

    const allowed = try memoryAllow(
        &g_fallback_table,
        &g_fallback_count,
        key,
        now_ms,
        window_ms,
        max,
    );
    if (!allowed) {
        ctx.res_status = .too_many_requests;
        try ctx.renderJson(.{ .@"error" = "rate_limit_exceeded" });
        return false;
    }
    return true;
}

/// Pure decision helper for unit tests: true when the window has rolled.
fn memoryWindowRolledOver(now_ms: i64, start_ms: i64, window_ms: i64) bool {
    return now_ms - start_ms >= window_ms;
}

test "memory fallback: window rollover logic" {
    try std.testing.expect(memoryWindowRolledOver(1_000_000, 900_000, 60_000));
    try std.testing.expect(!memoryWindowRolledOver(1_000_000, 950_000, 60_000));
    try std.testing.expect(!memoryWindowRolledOver(1_000_000, 1_000_000, 60_000));
    try std.testing.expect(memoryWindowRolledOver(2_000_000, 1_000_000, 60_000));
}

test "memory fallback: blocks once the limit is reached" {
    // The limiter used to fail open on every request: the slot scan stopped
    // at the high-water mark, which starts at zero, so it never found a free
    // slot and every request took the "table full" path. Without Redis — the
    // normal case for a self-hosted instance — that meant no rate limiting
    // at all, including on the auth endpoints.
    var slots: [8]FallbackEntry = undefined;
    for (&slots) |*slot| slot.* = .{};
    var count: usize = 0;

    for (0..3) |_| {
        try std.testing.expect(try memoryAllow(&slots, &count, "auth:1.2.3.4", 1_000, 60_000, 3));
    }
    // The fourth request in the same window exceeds the limit.
    try std.testing.expect(!try memoryAllow(&slots, &count, "auth:1.2.3.4", 1_000, 60_000, 3));

    // A different key has its own budget.
    try std.testing.expect(try memoryAllow(&slots, &count, "auth:5.6.7.8", 1_000, 60_000, 3));

    // After the window rolls over the key is allowed again.
    try std.testing.expect(try memoryAllow(&slots, &count, "auth:1.2.3.4", 61_000, 60_000, 3));
}

test "memory fallback: reuses slots instead of growing the table" {
    var slots: [2]FallbackEntry = undefined;
    for (&slots) |*slot| slot.* = .{};
    var count: usize = 0;

    try std.testing.expect(try memoryAllow(&slots, &count, "a:1", 1_000, 60_000, 10));
    try std.testing.expect(try memoryAllow(&slots, &count, "b:1", 1_000, 60_000, 10));
    try std.testing.expectEqual(@as(usize, 2), count);

    // "a" expires and frees its slot, which "c" then takes.
    try std.testing.expect(try memoryAllow(&slots, &count, "c:1", 61_000, 60_000, 10));
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "rate limit key is stable across a client's ephemeral source ports" {
    // The peer address used to be formatted with `{}`, which renders the
    // `IpAddress` Debug struct — "ip:port". The port is the client's
    // ephemeral source port, so every request produced a fresh key, every
    // request started a fresh window, and the limiter never blocked
    // anything. The key must depend on the client address only.
    var server: std.http.Server = undefined;
    _ = &server;
    var req: std.http.Server.Request = undefined;
    req.head = undefined;
    req.head.target = "/auth/send-code";

    var ctx = zfinal.Context.init(&req, std.testing.allocator);
    defer ctx.deinit();
    // Keep header lookups away from the (uninitialized) request head.
    ctx.mock_headers = std.StringHashMap([]const u8).init(std.testing.allocator);

    ctx.remote_addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 54321 } };
    const key_a = try rateLimitKey(&ctx);
    defer std.testing.allocator.free(key_a);

    ctx.remote_addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 65432 } };
    const key_b = try rateLimitKey(&ctx);
    defer std.testing.allocator.free(key_b);

    try std.testing.expectEqualStrings(key_a, key_b);

    // A different client still gets its own budget.
    ctx.remote_addr = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 5 }, .port = 54321 } };
    const key_c = try rateLimitKey(&ctx);
    defer std.testing.allocator.free(key_c);
    try std.testing.expect(!std.mem.eql(u8, key_a, key_c));
}

/// Client IP used as part of the rate-limit key.
///
/// The peer address must be formatted *without* its port. `ctx.remote_addr`
/// is an `IpAddress`, whose only `{}` formatting is the Debug struct — it
/// renders as "ip:port", and the port is the client's ephemeral source port,
/// which changes on every connection. Keying on it gave every request its
/// own budget, so the limiter never blocked anything.
///
/// zfinal's resolver formats the address as a bare IP and applies the
/// project's trusted-proxy policy, matching the request logger.
fn clientIp(ctx: *zfinal.Context, buf: []u8) []const u8 {
    const cfg = g_cfg;
    return zfinal.IpExt.resolveClientIp(ctx, buf, .{
        .trust_proxy_headers = if (cfg) |c| c.trusted_proxies.len > 0 else false,
        .trusted_proxies = if (cfg) |c| c.trusted_proxies else &.{},
    }) catch "unknown";
}

fn rateLimitKey(ctx: *zfinal.Context) ![]const u8 {
    const target = ctx.req.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    var normalized = try ctx.allocator.alloc(u8, path.len);
    defer ctx.allocator.free(normalized);
    for (path, 0..) |c, i| {
        normalized[i] = if (c == '/') ':' else c;
    }

    var ip_buf: [64]u8 = undefined;
    const ip = clientIp(ctx, &ip_buf);

    // Bare {path}:{ip} — the Redis path prepends the "mul:ratelimit:" key
    // prefix via zfinal.RedisRateLimiter; the in-memory fallback uses the
    // key as-is.
    return try std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{ normalized, ip });
}

fn checkRateLimit(ctx: *zfinal.Context, max: u32, window_seconds: u32) !bool {
    const key = try rateLimitKey(ctx);
    defer ctx.allocator.free(key);

    if (redis.client()) |client| {
        // Distributed fixed-window via zfinal.RedisRateLimiter (atomic
        // INCR + EXPIRE-on-first-hit, fail-closed on Redis errors). On
        // Redis failure we degrade to the in-memory limiter — limits are
        // always enforced, never silently skipped.
        var rl = zfinal.RedisRateLimiter.init(client, "mul:ratelimit:");
        const allowed = rl.allow(key, max, window_seconds) catch {
            log.warn("redis rate limit unavailable — falling back to in-memory limiter", .{});
            return try checkRateLimitMemory(ctx, max, window_seconds);
        };
        if (!allowed) {
            ctx.res_status = .too_many_requests;
            try ctx.renderJson(.{ .@"error" = "rate_limit_exceeded" });
            return false;
        }
        return true;
    }

    // No Redis → enforce the limit in-process instead of silently
    // skipping it. Per-instance rather than shared, but limits still apply.
    return try checkRateLimitMemory(ctx, max, window_seconds);
}

fn authSendCodeBefore(ctx: *zfinal.Context) !bool {
    const max = if (g_cfg) |cfg| cfg.rate_limit_auth else 5;
    return try checkRateLimit(ctx, max, 60);
}

fn authVerifyCodeBefore(ctx: *zfinal.Context) !bool {
    const max = if (g_cfg) |cfg| cfg.rate_limit_auth_verify else 20;
    return try checkRateLimit(ctx, max, 60);
}

/// Rate limiter for `/auth/send-code` using the configured `rate_limit_auth` limit.
pub const RateLimitAuthInterceptor = zfinal.Interceptor{
    .name = "ratelimit-auth-send-code",
    .before = authSendCodeBefore,
};

/// Rate limiter for `/auth/verify-code` using the configured `rate_limit_auth_verify` limit.
pub const RateLimitAuthVerifyInterceptor = zfinal.Interceptor{
    .name = "ratelimit-auth-verify-code",
    .before = authVerifyCodeBefore,
};

/// Generic rate limiter factory. Configures a fallback limit and returns the
/// generic interceptor; auth routes use the path-specific interceptors above so
/// the env-driven config limits are honored.
pub fn RateLimitInterceptor(max: u32, window_seconds: u32) zfinal.Interceptor {
    g_fallback = .{ .max = max, .window = window_seconds };
    return RateLimitGenericInterceptor;
}

fn genericBefore(ctx: *zfinal.Context) !bool {
    return try checkRateLimit(ctx, g_fallback.max, g_fallback.window);
}

pub const RateLimitGenericInterceptor = zfinal.Interceptor{
    .name = "ratelimit-generic",
    .before = genericBefore,
};
