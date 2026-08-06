//! Auth module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `code_map`) and
//! exposes the four HTTP-facing operations: `sendCode`, `verifyCode`,
//! `logout`, `googleAuth`. The `handler.zig` is a thin delegate; all
//! real work lives here and in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const auth = @import("../../auth.zig");
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const util = @import("../../util.zig");
const validation = @import("../../common/validation.zig");

const log = std.log.scoped(.auth_service);

const CodeEntry = struct {
    code: u32,
    expires_at: i64,
    attempts: u32,
    used: bool,
};

var g_cfg: ?*const Config = null;
var code_map: ?std.StringHashMap(CodeEntry) = null;
var code_mutex: std.Io.Mutex = std.Io.Mutex.init;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
    if (code_map == null) {
        code_map = std.StringHashMap(CodeEntry).init(std.heap.page_allocator);
    }
}

// ──────────────────────────────────────────────────────────────────────
// send-code
// ──────────────────────────────────────────────────────────────────────

const SendCodeRequest = struct {
    email: []const u8,
};

pub fn sendCode(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(SendCodeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const email_raw = std.mem.trim(u8, req.email, &std.ascii.whitespace);
    if (!validation.isValidEmail(email_raw)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "email is required" });
        return;
    }
    const email_lower = try util.dupeLower(ctx.allocator, email_raw);
    defer ctx.allocator.free(email_lower);

    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "auth not configured" });
        return;
    };

    // Existing users are always allowed to log in; new users must
    // pass signup gating.
    const existing = model.userExistsByEmail(email_lower);
    if (checkSignupAllowed(email_lower, !existing)) |reason| {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = reason });
        return;
    }

    const code = auth.generateCode();
    const code_str = try formatCode(code);
    defer std.heap.page_allocator.free(code_str);

    model.insertVerificationCode(email_lower, code_str);
    model.purgeExpiredCodes();

    // No-DB fallback: keep an in-memory record so `verifyCode`
    // works without Postgres during local dev / smoke tests.
    if (!deps.hasPool()) {
        try code_mutex.lock(zfinal.io_instance.io);
        defer code_mutex.unlock(zfinal.io_instance.io);

        const email_copy = try std.heap.page_allocator.dupe(u8, email_lower);
        errdefer std.heap.page_allocator.free(email_copy);
        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        try code_map.?.put(email_copy, .{
            .code = code,
            .expires_at = now + 60 * 10,
            .attempts = 0,
            .used = false,
        });
    }

    // Send the code by email when a delivery backend is configured
    // (Resend API; SMTP is not wired up yet in zserver). Without one we
    // fall back to the dev-mode print — matching the Go server's
    // unconfigured behaviour so local smoke/e2e keep working.
    if (cfg.resend_api_key != null) {
        sendVerificationEmail(ctx.allocator, cfg, email_lower, code_str) catch |err| {
            log.err("failed to send verification email to {s}: {}", .{ email_lower, err });
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to send verification code" });
            return;
        };
    } else {
        log.info("login code for {s}: {s}", .{ email_lower, code_str });
    }

    ctx.res_status = .ok;
    try ctx.renderJson(.{ .sent = true });
}

/// Send a verification code via the Resend HTTP API. Returns
/// `error.EmailSendFailed` on transport or non-2xx responses; the
/// caller decides whether to fail the request.
fn sendVerificationEmail(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    to: []const u8,
    code: []const u8,
) !void {
    const api_key = cfg.resend_api_key orelse return;
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"from\":\"{s}\",\"to\":[\"{s}\"],\"subject\":\"Your 1person verification code\"," ++
            "\"html\":\"<p style=\\\"font-size:28px;letter-spacing:4px;\\\">{s}</p>" ++
            "<p>This code expires in 10 minutes. If you didn't request it, you can safely ignore this email.</p>\"}}",
        .{ cfg.resend_from_email, to, code },
    );
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(bearer);

    const uri = std.Uri.parse("https://api.resend.com/emails") catch return error.EmailSendFailed;
    var client = std.http.Client{ .allocator = allocator, .io = zfinal.io_instance.io };
    defer client.deinit();
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
    });
    defer req.deinit();
    try req.sendBodyComplete(body);
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return error.EmailSendFailed;
}

// ──────────────────────────────────────────────────────────────────────
// verify-code
// ──────────────────────────────────────────────────────────────────────

const VerifyCodeRequest = struct {
    email: []const u8,
    code: []const u8,
};

pub fn verifyCode(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    const parsed = try ctx.parseJsonBody(VerifyCodeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "not_configured" });
        return;
    };

    const email_raw = std.mem.trim(u8, req.email, &std.ascii.whitespace);
    const code_raw = std.mem.trim(u8, req.code, &std.ascii.whitespace);
    if (!validation.isValidEmail(email_raw) or code_raw.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "email and code are required" });
        return;
    }
    const email_lower = try util.dupeLower(allocator, email_raw);
    defer allocator.free(email_lower);

    if (!isSixDigitCode(code_raw)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_or_expired_code" });
        return;
    }

    const dev_match = isDevCode(code_raw);

    var code_id: ?[]const u8 = null;
    var valid = false;

    if (deps.hasPool()) {
        defer if (code_id) |id| allocator.free(id);
        if (model.latestActiveCodeRow(email_lower)) |row| {
            if (dev_match or std.mem.eql(u8, code_raw, row.code)) {
                valid = true;
                code_id = try allocator.dupe(u8, row.id);
            } else {
                model.incrementCodeAttempts(row.id);
            }
        }
        if (valid) {
            if (code_id) |id| try model.markCodeUsed(id);
        }
    } else {
        try code_mutex.lock(zfinal.io_instance.io);
        const entry = code_map.?.getPtr(email_lower);
        if (entry) |e| {
            const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
            if (!e.used and e.expires_at >= now) {
                if (dev_match or e.code == std.fmt.parseInt(u32, code_raw, 10) catch 0) {
                    valid = true;
                    e.used = true;
                } else {
                    e.attempts += 1;
                }
            }
        }
        code_mutex.unlock(zfinal.io_instance.io);
    }

    if (!valid) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_or_expired_code" });
        return;
    }

    // Signup gating for new users.
    const existing_user = model.userExistsByEmail(email_lower);
    if (checkSignupAllowed(email_lower, !existing_user)) |reason| {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = reason });
        return;
    }

    // Upsert user.
    const user_id = blk: {
        if (deps.hasPool()) {
            const name = try fallbackName(allocator, email_lower);
            defer allocator.free(name);
            break :blk try model.upsertUserByEmail(email_lower, name);
        }
        break :blk try fallbackUserId(allocator, email_lower);
    };
    defer allocator.free(user_id);

    const token = try auth.createToken(allocator, cfg, user_id, email_lower);
    defer allocator.free(token);

    try auth.setAuthCookies(ctx, token);

    ctx.res_status = .ok;
    try ctx.renderJson(.{
        .token = token,
        .user = .{
            .id = user_id,
            .email = email_lower,
        },
    });
}

// ──────────────────────────────────────────────────────────────────────
// logout / google-auth
// ──────────────────────────────────────────────────────────────────────

pub fn logout(ctx: *zfinal.Context) !void {
    try auth.clearAuthCookies(ctx);
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .message = "logged out" });
}

const GoogleAuthRequest = struct {
    code: []const u8 = "",
    redirect_uri: ?[]const u8 = null,
};

/// Percent-encode a value for use in an `application/x-www-form-urlencoded`
/// body (RFC 3986 unreserved chars pass through; everything else becomes
/// `%XX`).
fn formUrlEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            const hex = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{c});
            defer allocator.free(hex);
            try out.appendSlice(allocator, hex);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// POST the authorization `code` to Google's token endpoint and return
/// the raw JSON body (`{access_token, id_token, ...}`) on success.
/// Returns `null` on any transport/non-2xx failure.
fn exchangeGoogleCode(
    allocator: std.mem.Allocator,
    code: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: ?[]const u8,
) !?[]u8 {
    const uri = std.Uri.parse("https://oauth2.googleapis.com/token") catch return null;
    var client = std.http.Client{ .allocator = allocator, .io = zfinal.io_instance.io };
    defer client.deinit();
    var req = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    });
    defer req.deinit();

    // Build the form body: code, client_id, client_secret, redirect_uri,
    // grant_type=authorization_code.
    var form = std.ArrayList(u8).empty;
    defer form.deinit(allocator);
    try form.appendSlice(allocator, "code=");
    const code_enc = try formUrlEncode(allocator, code);
    defer allocator.free(code_enc);
    try form.appendSlice(allocator, code_enc);
    try form.appendSlice(allocator, "&client_id=");
    const cid_enc = try formUrlEncode(allocator, client_id);
    defer allocator.free(cid_enc);
    try form.appendSlice(allocator, cid_enc);
    try form.appendSlice(allocator, "&client_secret=");
    const cs_enc = try formUrlEncode(allocator, client_secret);
    defer allocator.free(cs_enc);
    try form.appendSlice(allocator, cs_enc);
    if (redirect_uri) |ru| {
        if (ru.len > 0) {
            try form.appendSlice(allocator, "&redirect_uri=");
            const ru_enc = try formUrlEncode(allocator, ru);
            defer allocator.free(ru_enc);
            try form.appendSlice(allocator, ru_enc);
        }
    }
    try form.appendSlice(allocator, "&grant_type=authorization_code");

    try req.sendBodyComplete(form.items);
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var transfer_buf: [4096]u8 = undefined;
    const rdr = response.reader(&transfer_buf);
    while (true) {
        const n = rdr.readSliceShort(&transfer_buf) catch break;
        if (n == 0) break;
        try body.appendSlice(allocator, transfer_buf[0..n]);
    }
    return try body.toOwnedSlice(allocator);
}

/// Fetch Google userinfo (`{email, name, picture}`) with the access
/// token. Returns the raw JSON body on success, `null` otherwise.
fn fetchGoogleUserInfo(allocator: std.mem.Allocator, access_token: []const u8) !?[]u8 {
    const uri = std.Uri.parse("https://www.googleapis.com/oauth2/v2/userinfo") catch return null;
    var client = std.http.Client{ .allocator = allocator, .io = zfinal.io_instance.io };
    defer client.deinit();
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(bearer);
    var req = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = bearer } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var transfer_buf: [4096]u8 = undefined;
    const rdr = response.reader(&transfer_buf);
    while (true) {
        const n = rdr.readSliceShort(&transfer_buf) catch break;
        if (n == 0) break;
        try body.appendSlice(allocator, transfer_buf[0..n]);
    }
    return try body.toOwnedSlice(allocator);
}

pub fn googleAuth(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "auth not configured" });
        return;
    };

    const parsed = try ctx.parseJsonBody(GoogleAuthRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.code.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "code is required" });
        return;
    }

    const client_id = cfg.google_client_id orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "Google login is not configured" });
        return;
    };
    const client_secret = cfg.google_client_secret orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "Google login is not configured" });
        return;
    };

    // 1. Exchange the authorization code for an access token. This is
    // the security boundary: the code was minted by Google for this
    // client_id, so a successful exchange proves the client is real.
    const token_body = (try exchangeGoogleCode(allocator, req.code, client_id, client_secret, req.redirect_uri)) orelse {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to exchange code with Google" });
        return;
    };
    defer allocator.free(token_body);

    const access_token = blk: {
        var it = std.json.parseFromSliceLeaky(std.json.Value, allocator, token_body, .{}) catch {
            ctx.res_status = .bad_gateway;
            try ctx.renderJson(.{ .@"error" = "failed to parse Google token response" });
            return;
        };
        break :blk it.object.get("access_token") orelse {
            ctx.res_status = .bad_gateway;
            try ctx.renderJson(.{ .@"error" = "failed to parse Google token response" });
            return;
        };
    };
    if (access_token != .string or access_token.string.len == 0) {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to parse Google token response" });
        return;
    }

    // 2. Fetch the verified user profile from Google.
    const userinfo_body = (try fetchGoogleUserInfo(allocator, access_token.string)) orelse {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to fetch user info from Google" });
        return;
    };
    defer allocator.free(userinfo_body);

    const g_user = std.json.parseFromSliceLeaky(std.json.Value, allocator, userinfo_body, .{}) catch {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to parse Google user info" });
        return;
    };
    const email_val = g_user.object.get("email") orelse {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to parse Google user info" });
        return;
    };
    if (email_val != .string or email_val.string.len == 0) {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to parse Google user info" });
        return;
    }

    // 3. Log the user in with the verified email.
    const email_lower = try std.ascii.allocLowerString(allocator, std.mem.trim(u8, email_val.string, &std.ascii.whitespace));
    defer allocator.free(email_lower);

    const user_id = try fallbackUserId(allocator, email_lower);
    defer allocator.free(user_id);

    const token = try auth.createToken(allocator, cfg, user_id, email_lower);
    defer allocator.free(token);

    try auth.setAuthCookies(ctx, token);

    ctx.res_status = .ok;
    try ctx.renderJson(.{
        .token = token,
        .user = .{
            .id = user_id,
            .email = email_lower,
        },
    });
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn emailDomain(email: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return "";
    return email[at + 1 ..];
}

fn containsCi(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.ascii.eqlIgnoreCase(item, needle)) return true;
    }
    return false;
}

fn checkSignupAllowed(email: []const u8, is_new_user: bool) ?[]const u8 {
    const cfg = g_cfg orelse return null;
    if (!is_new_user) return null;

    const lower = std.ascii.lowerString;
    var email_buf: [256]u8 = undefined;
    var domain_buf: [256]u8 = undefined;
    const email_lower = if (email.len <= email_buf.len)
        lower(email_buf[0..email.len], email)
    else
        lower(std.heap.page_allocator.alloc(u8, email.len) catch return "signup_disabled", email);
    defer if (email.len > email_buf.len) std.heap.page_allocator.free(email_lower);

    if (cfg.allowed_emails.len > 0 and containsCi(cfg.allowed_emails, email_lower)) return null;

    const domain = emailDomain(email_lower);
    const domain_lower = if (domain.len <= domain_buf.len)
        lower(domain_buf[0..domain.len], domain)
    else
        lower(std.heap.page_allocator.alloc(u8, domain.len) catch return "signup_disabled", domain);
    defer if (domain.len > domain_buf.len) std.heap.page_allocator.free(domain_lower);

    if (cfg.allowed_email_domains.len > 0 and containsCi(cfg.allowed_email_domains, domain_lower)) return null;

    if (!cfg.app.allow_signup) return "user registration is disabled on this self-hosted instance";

    if (cfg.allowed_email_domains.len > 0 or cfg.allowed_emails.len > 0) return "user registration is disabled on this self-hosted instance";

    return null;
}

fn isDevCode(code: []const u8) bool {
    const cfg = g_cfg orelse return false;
    const dev = cfg.dev_verification_code orelse return false;
    return std.mem.eql(u8, code, dev);
}

fn isSixDigitCode(code: []const u8) bool {
    if (code.len != 6) return false;
    for (code) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn formatCode(code: u32) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{d:0>6}", .{code});
}

fn fallbackUserId(allocator: std.mem.Allocator, email: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(email, &hash, .{});
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

fn fallbackName(allocator: std.mem.Allocator, email: []const u8) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return allocator.dupe(u8, email);
    return allocator.dupe(u8, email[0..at]);
}
