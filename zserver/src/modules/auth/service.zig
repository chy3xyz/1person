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

    // TODO: send email via SMTP / SES.
    log.info("login code for {s}: {s}", .{ email_lower, code_str });

    ctx.res_status = .ok;
    try ctx.renderJson(.{ .sent = true });
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
    credential: []const u8,
    email: ?[]const u8 = null,
};

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

    if (req.credential.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "credential is required" });
        return;
    }

    const email = req.email orelse "google-user@example.com";
    const email_lower = try std.ascii.allocLowerString(allocator, std.mem.trim(u8, email, &std.ascii.whitespace));
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
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn fallbackName(allocator: std.mem.Allocator, email: []const u8) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return allocator.dupe(u8, email);
    return allocator.dupe(u8, email[0..at]);
}
