//! Redis-backed fixed-window rate limiting interceptor.

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

    return try std.fmt.allocPrint(ctx.allocator, "mul:ratelimit:{s}:{s}", .{ normalized, ip });
}

fn checkRateLimit(ctx: *zfinal.Context, max: u32, window_seconds: u32) !bool {
    const client = redis.client() orelse return true;

    const key = try rateLimitKey(ctx);
    defer ctx.allocator.free(key);

    // v0.20.9's RedisClient exposes only get/set/setEx/del/exists/expire/
    // publish/subscribe/ping — no INCR. Read-modify-write is non-atomic, but
    // a best-effort fixed window is acceptable for rate limiting.
    const prev: i64 = blk: {
        const cur = client.get(key) catch null;
        const raw = cur orelse break :blk 0;
        defer client.allocator.free(raw);
        break :blk std.fmt.parseInt(i64, raw, 10) catch 0;
    };
    const count = prev + 1;

    var count_buf: [32]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{count});
    // SETEX also refreshes the TTL, which keeps the window anchored to the
    // most recent request rather than the first one in the window.
    client.setEx(key, count_str, window_seconds) catch {};

    if (count > max) {
        ctx.res_status = .too_many_requests;
        try ctx.renderJson(.{ .@"error" = "rate_limit_exceeded" });
        return false;
    }

    return true;
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
