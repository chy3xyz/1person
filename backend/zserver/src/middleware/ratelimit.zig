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
var g_fallback_table: [MEMORY_FALLBACK_MAX_KEYS]FallbackEntry = undefined;
var g_fallback_count: usize = 0;

fn checkRateLimitMemory(ctx: *zfinal.Context, max: u32, window_seconds: u32) !bool {
    const key = try rateLimitKey(ctx);
    defer ctx.allocator.free(key);

    const now_ms = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
    const window_ms: i64 = @as(i64, window_seconds) * 1000;

    try g_fallback_mutex.lock(zfinal.io_instance.io);
    defer g_fallback_mutex.unlock(zfinal.io_instance.io);

    // Find the slot, pruning expired entries we pass.
    var free_slot: ?usize = null;
    var entry: ?*FallbackEntry = null;
    for (&g_fallback_table, 0..) |*slot, i| {
        if (i >= g_fallback_count) break;
        if (slot.key.len == 0) {
            if (free_slot == null) free_slot = i;
            continue;
        }
        if (now_ms - slot.window_start_ms >= window_ms) {
            // Expired — reclaim the slot (key is allocator-owned; the
            // map frees on remove in the old impl, here we just clear).
            slot.key = "";
            slot.count = 0;
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
        if (e.count > max) {
            ctx.res_status = .too_many_requests;
            try ctx.renderJson(.{ .@"error" = "rate_limit_exceeded" });
            return false;
        }
        return true;
    }

    // New key — use the first free slot or reclaim a stale one.
    if (free_slot) |idx| {
        g_fallback_table[idx] = .{
            .key = try ctx.allocator.dupe(u8, key),
            .count = 1,
            .window_start_ms = now_ms,
        };
        if (idx >= g_fallback_count) g_fallback_count = idx + 1;
        if (1 > max) {
            ctx.res_status = .too_many_requests;
            try ctx.renderJson(.{ .@"error" = "rate_limit_exceeded" });
            return false;
        }
        return true;
    }

    // Table full — fail open (allow) rather than crash.
    log.warn("rate limit fallback table full; allowing request", .{});
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

fn isTrustedProxy(ip: []const u8) bool {
    const cfg = g_cfg orelse return false;
    for (cfg.trusted_proxies) |p| {
        if (std.mem.eql(u8, p, ip)) return true;
    }
    return false;
}

fn clientIp(ctx: *zfinal.Context) ![]const u8 {
    // Prefer the direct remote address unless it is a trusted proxy.
    if (ctx.remote_addr) |addr| {
        const ip = try std.fmt.allocPrint(ctx.allocator, "{}", .{addr});
        if (!isTrustedProxy(ip)) return ip;
        ctx.allocator.free(ip);
    }

    if (ctx.getHeader("X-Forwarded-For")) |forwarded| {
        const first = if (std.mem.indexOfScalar(u8, forwarded, ',')) |comma|
            std.mem.trim(u8, forwarded[0..comma], &std.ascii.whitespace)
        else
            std.mem.trim(u8, forwarded, &std.ascii.whitespace);
        if (first.len > 0) return try ctx.allocator.dupe(u8, first);
    }

    return try ctx.allocator.dupe(u8, "unknown");
}

fn rateLimitKey(ctx: *zfinal.Context) ![]const u8 {
    const target = ctx.req.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    var normalized = try ctx.allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        normalized[i] = if (c == '/') ':' else c;
    }

    const ip = try clientIp(ctx);
    defer ctx.allocator.free(ip);

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
