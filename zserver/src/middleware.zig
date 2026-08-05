//! HTTP middleware/interceptors.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("config.zig").Config;
const auth_lib = @import("auth.zig");
const deps = @import("deps.zig");

const log = std.log.scoped(.middleware);

var g_cfg: ?*const Config = null;

pub fn setConfig(cfg: *const Config) void {
    g_cfg = cfg;
}

/// Owns the copy of the raw request head that `mock_headers` points into.
/// Stored in `ctx.extensions`, whose `deinit` always runs from
/// `Context.deinit`, so the copy is released even if a handler errors.
const HeaderSnapshot = struct { head: []u8 };

fn destroyHeaderSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *HeaderSnapshot = @ptrCast(@alignCast(ptr));
    allocator.free(self.head);
    allocator.destroy(self);
}

const MockHeaders = std.StringHashMap([]const u8);

/// True when `map` already holds `name` under any casing.
///
/// `mock_headers` is a `StringHashMap` keyed by the exact bytes of the
/// header name, but `Context.getHeader` matches case-insensitively, so
/// `X-Foo` and `x-foo` would be two map entries that a single lookup can
/// resolve to either way (hash order, not insertion order). Checking with
/// the same case-insensitive rule `getHeader` uses keeps the two in sync.
fn mockHeaderPresent(map: *const MockHeaders, name: []const u8) bool {
    var it = map.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) return true;
    }
    return false;
}

/// Copy every header in `head` into `map`, first match wins.
///
/// This mirrors the reader path the snapshot replaces: `getHeader` over
/// `req.iterateHeaders()` returns the *first* header with a matching
/// name. `StringHashMap.put` overwrites, so a blind loop would flip
/// duplicated headers (two `X-Forwarded-For:` lines, say) to last-match.
/// Skipping names already recorded preserves the original semantics.
///
/// Keys and values are borrowed from `head`, which must outlive `map`.
fn seedMockHeaders(map: *MockHeaders, head: []const u8) !void {
    var it = std.http.HeaderIterator.init(head);
    while (it.next()) |header| {
        if (mockHeaderPresent(map, header.name)) continue;
        try map.put(header.name, header.value);
    }
}

/// Copy the request headers up front so later lookups never touch the
/// connection reader.
///
/// `Context.getHeader` reads through `req.iterateHeaders()`, which asserts
/// the reader is still at `.received_head`. Once a handler consumes the
/// request body that assert fails, and zfinal's own `clientAcceptsGzip`
/// (reached from `renderJson` for any response >= 256 bytes) calls
/// `getHeader` — so every "read a JSON body, return a large response"
/// handler would panic its worker thread. `getHeader` checks `mock_headers`
/// first and returns from there without going near the reader, so seeding it
/// here makes the whole request safe. The header slices point into a private
/// copy of the head buffer, because the reader reuses the original bytes for
/// body data.
pub fn headerSnapshotBefore(ctx: *zfinal.Context) !bool {
    // Capture-mode / unit tests supply their own headers.
    if (ctx.mock_headers != null) return true;

    const snapshot = try ctx.allocator.create(HeaderSnapshot);
    snapshot.* = .{ .head = &.{} };
    // Transfer ownership before allocating the copy so a later failure
    // cannot leak it.
    ctx.extensions.set(ctx.allocator, HeaderSnapshot, snapshot, destroyHeaderSnapshot) catch |err| {
        ctx.allocator.destroy(snapshot);
        return err;
    };
    snapshot.head = try ctx.allocator.dupe(u8, ctx.req.head_buffer);

    // `Context.deinit` owns the map from here on (it deinits
    // `mock_headers` unconditionally), same as `setMockHeader`'s lazy init.
    ctx.mock_headers = MockHeaders.init(ctx.allocator);
    try seedMockHeaders(&ctx.mock_headers.?, snapshot.head);
    return true;
}

pub const HeaderSnapshotInterceptor = zfinal.Interceptor{
    .name = "header-snapshot",
    .before = headerSnapshotBefore,
};

/// CORS before interceptor. Allows configured origins and handles preflight.
pub fn corsBefore(ctx: *zfinal.Context) !bool {
    const cfg = g_cfg orelse return true;

    const origin = ctx.getHeader("origin") orelse "";
    const allowed = isOriginAllowed(origin, cfg.allowed_origins);

    if (allowed) {
        try ctx.setHeader("Access-Control-Allow-Origin", origin);
        try ctx.setHeader("Access-Control-Allow-Credentials", "true");
    } else if (cfg.allowed_origins.len == 0 or (cfg.allowed_origins.len == 1 and std.mem.eql(u8, cfg.allowed_origins[0], "*"))) {
        try ctx.setHeader("Access-Control-Allow-Origin", "*");
    }

    try ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS");
    try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With, X-CLI-Token, X-CSRF-Token, X-Workspace-ID, X-Workspace-Slug");
    try ctx.setHeader("Access-Control-Max-Age", "86400");

    if (ctx.req.head.method == .OPTIONS) {
        ctx.res_status = .ok;
        try ctx.renderText("");
        return false;
    }

    return true;
}

pub const CORSInterceptor = zfinal.Interceptor{
    .name = "cors",
    .before = corsBefore,
};

fn isOriginAllowed(origin: []const u8, allowed: []const []const u8) bool {
    if (origin.len == 0) return false;
    for (allowed) |a| {
        if (std.mem.eql(u8, a, "*")) return true;
        if (std.mem.eql(u8, a, origin)) return true;
    }
    return false;
}

/// Request logging interceptor.
pub fn logBefore(ctx: *zfinal.Context) !bool {
    const req_id = ctx.getHeader("x-request-id") orelse "";
    if (req_id.len > 0) {
        try ctx.setHeader("X-Request-Id", req_id);
    }
    try ctx.setAttr("req_id", req_id);
    try ctx.setAttr("req_method", @tagName(ctx.req.head.method));
    try ctx.setAttr("req_target", ctx.req.head.target);

    const start_ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const start_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{start_ns});
    defer ctx.allocator.free(start_str);
    try ctx.setAttr("req_start_ns", start_str);

    return true;
}

pub fn logAfter(ctx: *zfinal.Context) !void {
    const start_str = ctx.attributes.get("req_start_ns") orelse return;
    const start_ns = std.fmt.parseInt(i64, start_str, 10) catch return;
    const duration_ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds() - start_ns;
    const duration_us = @divFloor(duration_ns, 1000);

    const req_id = ctx.attributes.get("req_id") orelse "";
    const user_id = ctx.attributes.get("user_id") orelse "";
    const method = ctx.attributes.get("req_method") orelse "";
    const target = ctx.attributes.get("req_target") orelse "";
    const status = @intFromEnum(ctx.res_status);

    log.info("{s} {s} status={d} duration_us={d} user_id={s} req_id={s}", .{
        method, target, status, duration_us, user_id, req_id,
    });
}

pub const LoggingInterceptor = zfinal.Interceptor{
    .name = "log",
    .before = logBefore,
    .after = logAfter,
};

/// Assigns a request id if not present.
pub fn requestIdBefore(ctx: *zfinal.Context) !bool {
    if (ctx.getHeader("x-request-id") == null) {
        var bytes: [8]u8 = undefined;
        const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
        std.mem.writeInt(u64, &bytes, @intCast(ts), .big);
        const id = try std.fmt.allocPrint(ctx.allocator, "{x}", .{std.mem.readInt(u64, &bytes, .big)});
        defer ctx.allocator.free(id);
        try ctx.setHeader("X-Request-Id", id);
    }
    return true;
}

pub const RequestIdInterceptor = zfinal.Interceptor{
    .name = "request-id",
    .before = requestIdBefore,
};

fn isStateChanging(method: std.http.Method) bool {
    return method == .POST or method == .PUT or method == .PATCH or method == .DELETE;
}

fn tokenFromCookie(ctx: *zfinal.Context) !?[]const u8 {
    return try ctx.getCookie("multica_auth");
}

/// Authentication interceptor. Skips OPTIONS and public paths.
/// Verify a `mul_` personal access token against the
/// `personal_access_token` table (token_hash + revoked + expiry), the
/// same contract as the Go server's mul_ branch. On success stamps
/// `token_type`/`token_value`/`user_id` on the context. Falls back to
/// format-only in no-DB mode so dev smoke/e2e keep working.
fn validatePersonalToken(ctx: *zfinal.Context, token: []const u8) !bool {
    if (!deps.hasPool()) {
        try ctx.setAttr("token_type", "personal");
        try ctx.setAttr("token_value", token);
        return true;
    }
    const hash = try auth_lib.hashToken(ctx.allocator, token);
    defer ctx.allocator.free(hash);

    const db = deps.acquire() catch {
        try ctx.setAttr("token_type", "personal");
        try ctx.setAttr("token_value", token);
        return true;
    };
    defer deps.releaseBack(db);

    var rs = try db.queryParams(
        "SELECT user_id::text FROM personal_access_token " ++
            "WHERE token_hash = $1 AND revoked = false AND (expires_at IS NULL OR expires_at > now())",
        &[_]zfinal.SqlParam{.{ .text = hash }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    }
    const user_id = rs.rows.items[0].getText(0) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    };
    try ctx.setAttr("token_type", "personal");
    try ctx.setAttr("token_value", token);
    try ctx.setAttr("user_id", user_id);
    return true;
}

/// Verify a `mat_` task token against the `task_token` table, stamping
/// the bound (user_id, agent_id, task_id, workspace_id) — the same
/// authoritative identity mapping as the Go server's mat_ branch.
/// Falls back to format-only in no-DB mode.
fn validateTaskToken(ctx: *zfinal.Context, token: []const u8) !bool {
    if (!deps.hasPool()) {
        try ctx.setAttr("token_type", "task");
        try ctx.setAttr("token_value", token);
        return true;
    }
    const hash = try auth_lib.hashToken(ctx.allocator, token);
    defer ctx.allocator.free(hash);

    const db = deps.acquire() catch {
        try ctx.setAttr("token_type", "task");
        try ctx.setAttr("token_value", token);
        return true;
    };
    defer deps.releaseBack(db);

    var rs = try db.queryParams(
        "SELECT user_id::text, agent_id::text, task_id::text, workspace_id::text " ++
            "FROM task_token WHERE token_hash = $1 AND expires_at > now()",
        &[_]zfinal.SqlParam{.{ .text = hash }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    }
    const row = &rs.rows.items[0];
    const user_id = row.getText(0) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    };
    try ctx.setAttr("token_type", "task");
    try ctx.setAttr("token_value", token);
    try ctx.setAttr("user_id", user_id);
    if (row.getText(1)) |agent_id| try ctx.setAttr("agent_id", agent_id);
    if (row.getText(2)) |task_id| try ctx.setAttr("task_id", task_id);
    if (row.getText(3)) |workspace_id| try ctx.setAttr("workspace_id", workspace_id);
    return true;
}

pub fn authBefore(ctx: *zfinal.Context) !bool {
    const cfg = g_cfg orelse return true;

    if (ctx.req.head.method == .OPTIONS) return true;

    const path = ctx.req.head.target;
    if (isPublicPath(path)) return true;

    const from_header = auth_lib.tokenFromRequest(ctx);
    const from_cookie = try tokenFromCookie(ctx);
    const token = from_header orelse from_cookie orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "missing_token" });
        return false;
    };

    // Cookie-authenticated state-changing requests require a valid CSRF token.
    if (from_header == null and isStateChanging(ctx.req.head.method)) {
        const csrf_header = ctx.getHeader("X-CSRF-Token") orelse {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invalid_csrf_token" });
            return false;
        };
        const expected = try auth_lib.csrfTokenFor(ctx.allocator, token);
        defer ctx.allocator.free(expected);
        if (!std.mem.eql(u8, expected, csrf_header)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invalid_csrf_token" });
            return false;
        }
    }

    switch (auth_lib.detectTokenType(token)) {
        .personal => {
            if (try validatePersonalToken(ctx, token)) return true;
            return false;
        },
        .task => {
            if (try validateTaskToken(ctx, token)) return true;
            return false;
        },
        .cloud_node => {
            // The Go server rejects `mcn_` tokens when the Multica
            // Cloud Fleet verifier is not configured (failing closed
            // rather than silently downgrading auth). zserver has no
            // Cloud integration, so every `mcn_` token is rejected.
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "invalid_token" });
            return false;
        },
        .daemon => {
            // Daemon tokens (`mdt_<id>`) are validated by the
            // dedicated `DaemonAuth` middleware. The global auth
            // interceptor only needs to mark the token type so
            // downstream middleware can recognise it.
            if (token.len < 5) { // "mdt_" + at least 1 char
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .@"error" = "invalid_token" });
                return false;
            }
            const daemon_id = auth_lib.daemonIdFromToken(token) orelse {
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .@"error" = "invalid_token" });
                return false;
            };
            try ctx.setAttr("token_type", "daemon");
            try ctx.setAttr("daemon_id", daemon_id);
            return true;
        },
        .jwt => {
            const token_info = auth_lib.validateToken(ctx.allocator, cfg, token) catch |err| {
                log.warn("token validation failed: {}", .{err});
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .@"error" = "invalid_token" });
                return false;
            };

            try ctx.setAttr("user_id", token_info.user_id);
            try ctx.setAttr("email", token_info.email);
            return true;
        },
    }
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};

fn isPublicPath(path: []const u8) bool {
    const public_paths = [_][]const u8{
        "/health",
        "/readyz",
        "/healthz",
        "/api/config",
        "/api/contact-sales",
        "/auth/send-code",
        "/auth/verify-code",
        "/auth/google",
        "/ws",
        "/api/webhooks/",
        "/api/github/setup",
        "/api/lark/binding/redeem",
    };
    for (public_paths) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

/// Security headers interceptor.
pub fn securityHeadersBefore(ctx: *zfinal.Context) !bool {
    try ctx.setHeader("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws: wss:; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data: blob:; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';");
    try ctx.setHeader("X-Content-Type-Options", "nosniff");
    try ctx.setHeader("X-Frame-Options", "DENY");
    try ctx.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    return true;
}

pub const SecurityHeadersInterceptor = zfinal.Interceptor{
    .name = "security-headers",
    .before = securityHeadersBefore,
};

/// Panic recovery interceptor. Catches handler errors and returns 500.
pub fn recoverAfter(ctx: *zfinal.Context) !void {
    _ = ctx;
    // zfinal dispatch already catches errors; this hook is for future metrics/logging.
}

pub const RecoverInterceptor = zfinal.Interceptor{
    .name = "recover",
    .after = recoverAfter,
};

// ──────────────────────────────────────────────────────────────────────
// tests
// ──────────────────────────────────────────────────────────────────────

/// Case-insensitive lookup with the same rule `Context.getHeader` applies
/// to `mock_headers`.
fn lookupMockHeader(map: *const MockHeaders, name: []const u8) ?[]const u8 {
    var it = map.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) return e.value_ptr.*;
    }
    return null;
}

test "seedMockHeaders: duplicated header keeps the first value" {
    const head =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Forwarded-For: 10.0.0.1\r\n" ++
        "X-Forwarded-For: 10.0.0.2\r\n" ++
        "\r\n";

    var map = MockHeaders.init(std.testing.allocator);
    defer map.deinit();
    try seedMockHeaders(&map, head);

    try std.testing.expectEqualStrings("10.0.0.1", lookupMockHeader(&map, "X-Forwarded-For").?);
}

test "seedMockHeaders: case-variant duplicate does not create a second entry" {
    // `put` keys on exact bytes, so `X-Foo` and `x-foo` would both land in
    // the map and `getHeader` would resolve to whichever hashes first.
    const head =
        "GET / HTTP/1.1\r\n" ++
        "X-Foo: first\r\n" ++
        "x-foo: second\r\n" ++
        "\r\n";

    var map = MockHeaders.init(std.testing.allocator);
    defer map.deinit();
    try seedMockHeaders(&map, head);

    try std.testing.expectEqual(@as(u32, 1), map.count());
    try std.testing.expectEqualStrings("first", lookupMockHeader(&map, "x-foo").?);
}

test "seedMockHeaders: distinct headers are all retained" {
    const head =
        "POST /api/x HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Accept-Encoding: gzip\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";

    var map = MockHeaders.init(std.testing.allocator);
    defer map.deinit();
    try seedMockHeaders(&map, head);

    try std.testing.expectEqual(@as(u32, 3), map.count());
    try std.testing.expectEqualStrings("gzip", lookupMockHeader(&map, "accept-encoding").?);
    try std.testing.expectEqualStrings("application/json", lookupMockHeader(&map, "CONTENT-TYPE").?);
    try std.testing.expect(lookupMockHeader(&map, "authorization") == null);
}
