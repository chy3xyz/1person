//! JWT authentication, cookies, and token-type detection.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.auth);

var g_cfg: ?*const Config = null;

pub fn setConfig(cfg: *const Config) void {
    g_cfg = cfg;
}

pub fn getConfig() ?*const Config {
    return g_cfg;
}

pub const Error = error{
    MissingToken,
    InvalidToken,
    InvalidSignature,
    Expired,
    InvalidFormat,
    OutOfMemory,
    InvalidCharacter,
    InvalidPadding,
    NoSpaceLeft,
    Overflow,
    NotConfigured,
};

pub const TokenType = enum {
    jwt,
    personal,
    task,
    cloud_node,
    daemon,
};

const JwtHeader = struct {
    alg: []const u8,
    typ: []const u8,
};

const JwtPayload = struct {
    sub: []const u8, // user id
    email: []const u8,
    iat: i64,
    exp: i64,
};

pub const UserToken = struct {
    user_id: []const u8,
    email: []const u8,
};

/// Detect the kind of bearer/cookie token.
pub fn detectTokenType(token: []const u8) TokenType {
    if (std.mem.startsWith(u8, token, "mul_")) return .personal;
    if (std.mem.startsWith(u8, token, "mat_")) return .task;
    if (std.mem.startsWith(u8, token, "mcn_")) return .cloud_node;
    if (std.mem.startsWith(u8, token, "mdt_")) return .daemon;
    return .jwt;
}

/// Extract the daemon id from a `mdt_<id>` token. Returns null when
/// the token doesn't carry the daemon prefix.
pub fn daemonIdFromToken(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "mdt_")) return null;
    const id = token[4..];
    if (id.len == 0) return null;
    return id;
}

/// Extract bearer token from Authorization header.
pub fn tokenFromRequest(ctx: *zfinal.Context) ?[]const u8 {
    const auth = ctx.getHeader("Authorization") orelse return null;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth, prefix)) return null;
    return std.mem.trim(u8, auth[prefix.len..], &std.ascii.whitespace);
}

/// Extract token from the HttpOnly auth cookie.
pub fn tokenFromCookie(ctx: *zfinal.Context) !?[]const u8 {
    return try ctx.getCookie("multica_auth");
}

/// Validate a JWT access token and return the user id and email.
pub fn validateToken(allocator: std.mem.Allocator, cfg: *const Config, token: []const u8) Error!UserToken {
    const secret = cfg.jwt_secret;

    var parts_it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts_it.next() orelse return error.InvalidFormat;
    const payload_b64 = parts_it.next() orelse return error.InvalidFormat;
    const signature_b64 = parts_it.next() orelse return error.InvalidFormat;
    if (parts_it.next() != null) return error.InvalidFormat;

    const header_json = try base64UrlDecode(allocator, header_b64);
    defer allocator.free(header_json);
    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    const header = std.json.parseFromSlice(JwtHeader, allocator, header_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidFormat;
    defer header.deinit();

    if (!std.mem.eql(u8, header.value.alg, "HS256")) return error.InvalidSignature;

    // Verify signature: HMACSHA256(header + "." + payload, secret)
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing_input, secret);

    const expected_sig = try base64UrlEncode(allocator, &mac);
    defer allocator.free(expected_sig);

    if (!std.mem.eql(u8, expected_sig, signature_b64)) return error.InvalidSignature;

    const payload = std.json.parseFromSlice(JwtPayload, allocator, payload_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidFormat;
    defer payload.deinit();

    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    if (payload.value.exp < now) return error.Expired;

    return UserToken{
        .user_id = try allocator.dupe(u8, payload.value.sub),
        .email = try allocator.dupe(u8, payload.value.email),
    };
}

/// Generate a JWT access token. Caller owns returned string.
pub fn createToken(allocator: std.mem.Allocator, cfg: *const Config, user_id: []const u8, email: []const u8) Error![]const u8 {
    const secret = cfg.jwt_secret;

    const header = .{ .alg = "HS256", .typ = "JWT" };
    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const payload = .{
        .sub = user_id,
        .email = email,
        .iat = now,
        .exp = now + cfg.auth_token_ttl,
    };

    const header_json = try std.json.Stringify.valueAlloc(allocator, header, .{});
    defer allocator.free(header_json);
    const payload_json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(payload_json);

    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing_input, secret);

    const signature_b64 = try base64UrlEncode(allocator, &mac);
    defer allocator.free(signature_b64);

    return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature_b64 });
}

/// Base64url decode (no padding).
fn base64UrlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Our encoder omits padding; accept tokens that may still contain trailing '='.
    const end = std.mem.indexOfScalar(u8, input, '=') orelse input.len;
    const payload = input[0..end];

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_size = try decoder.calcSizeForSlice(payload);
    const out = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(out);
    try decoder.decode(out, payload);
    return out;
}

/// Base64url encode (no padding).
fn base64UrlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(input.len));
    errdefer allocator.free(out);
    return encoder.encode(out, input);
}

/// Generate a personal access token: "mul_" + 40 random hex chars.
pub fn generatePersonalAccessToken(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [20]u8 = undefined;
    try zfinal.io_instance.io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return try std.fmt.allocPrint(allocator, "mul_{s}", .{hex});
}

/// Hash a token with SHA-256 and return the hex-encoded digest.
pub fn hashToken(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(allocator, "{s}", .{hex});
}

/// Generate a short numeric login code.
pub fn generateCode() u32 {
    var bytes: [4]u8 = undefined;
    zfinal.io_instance.io.randomSecure(&bytes) catch {
        // Entropy unavailable (extremely rare): fall back to a
        // time-derived value rather than failing the login flow.
        const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
        return @intCast(100000 + @mod(ts, 900000));
    };
    const n = std.mem.readInt(u32, bytes[0..4], .little);
    return 100000 + (n % 900000);
}

/// Derive a CSRF token from the auth token using a keyed HMAC.
pub fn csrfTokenFor(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    const secret = if (g_cfg) |cfg| cfg.jwt_secret else "dev-jwt-secret-change-me";
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, token, secret);

    const hex_len = mac.len * 2;
    const out = try allocator.alloc(u8, hex_len);
    const charset = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

/// Set the auth and CSRF cookies for a successful login/session.
pub fn setAuthCookies(ctx: *zfinal.Context, token: []const u8) !void {
    const cfg = g_cfg orelse return error.NotConfigured;
    const ttl = cfg.auth_token_ttl;
    const csrf = try csrfTokenFor(ctx.allocator, token);
    defer ctx.allocator.free(csrf);

    try ctx.setCookieFull("multica_auth", token, @intCast(ttl), "/", true, true, false);
    try ctx.setCookieFull("multica_csrf", csrf, @intCast(ttl), "/", false, true, false);
}

/// Clear the auth and CSRF cookies.
pub fn clearAuthCookies(ctx: *zfinal.Context) !void {
    try ctx.setCookieFull("multica_auth", "", 0, "/", true, true, false);
    try ctx.setCookieFull("multica_csrf", "", 0, "/", false, true, false);
}
