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
    count: u32,
    window_start_ms: i64,
};

const MEMORY_FALLBACK_MAX_KEYS: usize = 4096;

var g_fallback_mutex: std.Io.Mutex = .init;
var g_fallback_map: ?std.StringHashMap(FallbackEntry) = null;
var g_fallback_initialized: bool = false;

fn ensureFallbackMap() !void {
    // No lock-free fast path: the first callers race on g_fallback_map
    // and a hash map grown concurrently corrupts its buckets (observed
    // as putAssumeCapacityNoClobber assertion failures under parallel
    // request load). Always take the mutex; the cost is one uncontended
    // lock per request while the map is warm.
    try g_fallback_mutex.lock(zfinal.io_instance.io);
    defer g_fallback_mutex.unlock(zfinal.io_instance.io);
    if (g_fallback_initialized) return;
    g_fallback_map = std.StringHashMap(FallbackEntry).init(std.heap.page_allocator);
    g_fallback_initialized = true;
}

fn checkRateLimitMemory(ctx: *zfinal.Context, max: u32, window_seconds: u32) !bool {
    try ensureFallbackMap();
    const map = &g_fallback_map.?;

    const key = try rateLimitKey(ctx);
    defer ctx.allocator.free(key);

    const now_ms = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
    const window_ms: i64 = @as(i64, window_seconds) * 1000;

    try g_fallback_mutex.lock(zfinal.io_instance.io);
    defer g_fallback_mutex.unlock(zfinal.io_instance.io);

    if (map.getPtr(key)) |entry| {
        // Window rolled over: restart the count.
        if (now_ms - entry.window_start_ms >= window_ms) {
            entry.count = 0;
            entry.window_start_ms = now_ms;
        }
    } else {
        if (map.count() >= MEMORY_FALLBACK_MAX_KEYS) {
            // Bound memory: drop entries outside the current window.
            // Collect keys first and remove after iteration — mutating a
            // StringHashMap while iterating can invalidate its internal
            // bucket state and corrupt subsequent grows.
            var stale: std.ArrayList([]const u8) = .empty;
            defer stale.deinit(std.heap.page_allocator);
            var it = map.iterator();
            while (it.next()) |kv| {
                if (now_ms - kv.value_ptr.window_start_ms >= window_ms) {
                    stale.append(std.heap.page_allocator, kv.key_ptr.*) catch {};
                }
            }
            for (stale.items) |k| _ = map.remove(k);
        }
        try map.put(key, .{ .count = 0, .window_start_ms = now_ms });
    }

    const entry = map.getPtr(key).?;
    entry.count += 1;
    if (entry.count > max) {
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
