//! Webhook module — business logic.
//!
//! Owns `g_cfg` and the in-memory `mem_payloads` ring (last 100
//! entries). The three signing-secret flows (autopilot, GitHub,
//! Stripe) each verify the relevant header and only fall through to
//! the in-memory store when no secret is configured OR the signature
//! is valid. `handler.zig` is a thin delegate.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const autopilot = @import("../autopilot/service.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");

const log = std.log.scoped(.webhook_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_payloads: ?std.ArrayList(model.WebhookPayloadEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn ensurePayloads() !void {
    if (mem_payloads == null) {
        mem_payloads = std.ArrayList(model.WebhookPayloadEntry).empty;
    }
}

fn nowString() ![]const u8 {
        return common_mem.nowString();
    }

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn recordPayload(source: []const u8, payload: []const u8, signature_valid: bool) !void {
    try ensurePayloads();
    const id = try model.generateId(memAlloc(), source);
    const entry = model.WebhookPayloadEntry{
        .id = id,
        .source = try memDup(source),
        .received_at = try nowString(),
        .signature_valid = signature_valid,
        .payload = try memDup(payload),
    };
    try mem_payloads.?.append(memAlloc(), entry);
    // Keep the last 100 payloads to avoid unbounded growth.
    while (mem_payloads.?.items.len > 100) {
        const old = mem_payloads.?.orderedRemove(0);
        memAlloc().free(old.id);
        memAlloc().free(old.source);
        memAlloc().free(old.received_at);
        memAlloc().free(old.payload);
    }
}

fn hmacSha256(secret: []const u8, message: []const u8) [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, message, secret);
    return mac;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return s.len > 0;
}

fn hexDigest(mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8) [64]u8 {
    var out: [64]u8 = undefined;
    const charset = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

fn verifyHmacHex(secret: []const u8, body: []const u8, header: []const u8) bool {
    const sig = blk: {
        const trimmed = std.mem.trim(u8, header, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "sha256=")) {
            break :blk trimmed[7..];
        }
        break :blk trimmed;
    };
    if (sig.len != 64 or !isHex(sig)) return false;
    const expected_mac = hmacSha256(secret, body);
    const expected_hex = hexDigest(expected_mac);
    return std.mem.eql(u8, &expected_hex, sig);
}

fn verifyStripeSignature(secret: []const u8, body: []const u8, header: []const u8) bool {
    var timestamp: ?i64 = null;
    var sig_to_verify: ?[]const u8 = null;

    var parts = std.mem.splitScalar(u8, header, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "t=")) {
            const ts_str = trimmed[2..];
            timestamp = std.fmt.parseInt(i64, ts_str, 10) catch null;
        } else if (std.mem.startsWith(u8, trimmed, "v1=")) {
            sig_to_verify = trimmed[3..];
        }
    }

    const ts = timestamp orelse return false;
    const sig = sig_to_verify orelse return false;
    if (sig.len != 64 or !isHex(sig)) return false;

    // Reject signatures outside a 5-minute window.
    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    if (@abs(now - ts) > 300) return false;

    const signed_payload = std.fmt.allocPrint(std.heap.page_allocator, "{d}.{s}", .{ ts, body }) catch return false;
    defer std.heap.page_allocator.free(signed_payload);

    const expected_mac = hmacSha256(secret, signed_payload);
    const expected_hex = hexDigest(expected_mac);
    return std.mem.eql(u8, &expected_hex, sig);
}

pub fn autopilotWebhook(ctx: *zfinal.Context) !void {
    const token = ctx.getPathParam("token") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "token is required" });
        return;
    };

    const valid_token = try autopilot.isValidWebhookToken(token);
    if (!valid_token) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "unknown webhook token" });
        return;
    }

    const secret = try autopilot.getSigningSecretForWebhookToken(token);
    const sig_header = if (secret != null)
        ctx.getHeader("X-Autopilot-Signature") orelse
            ctx.getHeader("X-Signature") orelse
            ctx.getHeader("X-Hub-Signature-256") orelse ""
    else
        "";

    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);

    var verified = false;
    if (secret) |s| {
        if (sig_header.len == 0 or !verifyHmacHex(s, body, sig_header)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "invalid signature" });
            return;
        }
        verified = true;
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try recordPayload("autopilot", body, verified);

    try ctx.renderJson(.{ .success = true, .token = token });
}

pub fn githubWebhook(ctx: *zfinal.Context) !void {
    const cfg = g_cfg.?;
    const sig_header = if (cfg.github_webhook_secret != null)
        ctx.getHeader("X-Hub-Signature-256") orelse ""
    else
        "";

    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);

    var verified = false;
    if (cfg.github_webhook_secret) |secret| {
        if (sig_header.len == 0 or !verifyHmacHex(secret, body, sig_header)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "invalid signature" });
            return;
        }
        verified = true;
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try recordPayload("github", body, verified);

    try ctx.renderJson(.{ .success = true });
}

pub fn githubSetup(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "not configured" });
        return;
    };

    const webhook_url = if (cfg.public_url.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/api/github/webhook", .{cfg.public_url})
    else
        try allocator.dupe(u8, "/api/github/webhook");
    defer allocator.free(webhook_url);

    try ctx.renderJson(.{
        .success = true,
        .webhook_url = webhook_url,
        .has_webhook_secret = cfg.github_webhook_secret != null,
        .events = &[_][]const u8{ "issues", "issue_comment", "pull_request", "push" },
    });
}

pub fn stripeWebhook(ctx: *zfinal.Context) !void {
    const cfg = g_cfg.?;
    const sig_header = if (cfg.stripe_webhook_secret != null)
        ctx.getHeader("Stripe-Signature") orelse ""
    else
        "";

    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);

    var verified = false;
    if (cfg.stripe_webhook_secret) |secret| {
        if (sig_header.len == 0 or !verifyStripeSignature(secret, body, sig_header)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "invalid signature" });
            return;
        }
        verified = true;
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try recordPayload("stripe", body, verified);

    try ctx.renderJson(.{ .success = true });
}
