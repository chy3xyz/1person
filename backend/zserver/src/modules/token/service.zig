//! Personal access token module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_tokens` +
//! `mem_hashes`) and exposes the four HTTP-facing operations:
//! `listTokens`, `createToken`, `renewCurrentToken`, `revokeToken`.
//! The `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const response = @import("../../common/response.zig");
const zfinal = @import("zfinal");
const auth = @import("../../auth.zig");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const SqlParam = zfinal.SqlParam;
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");

const log = std.log.scoped(.token_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_tokens: ?std.StringHashMap(model.PatEntry) = null;
var mem_hashes: ?std.StringHashMap([]const u8) = null; // hash -> id

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_tokens == null) {
        mem_tokens = std.StringHashMap(model.PatEntry).init(memAlloc());
        mem_hashes = std.StringHashMap([]const u8).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn memGenerateId() ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    var bytes: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(ns));
    prng.random().bytes(&bytes);
    const payload = try std.fmt.allocPrint(memAlloc(), "{d}{s}", .{ ns, std.fmt.bytesToHex(bytes, .lower) });
    defer memAlloc().free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try memAlloc().alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn getCurrentUser(ctx: *zfinal.Context) ?model.CurrentUser {
    const id = ctx.attributes.get("user_id") orelse return null;
    const email = ctx.attributes.get("email") orelse return null;
    return model.CurrentUser{ .id = id, .email = email };
}

/// Resolve the caller's user id from JWT attributes or, for PAT auth, by
/// looking up the bearer token. Returns null when unauthenticated.
fn resolveCaller(ctx: *zfinal.Context) !?model.CurrentUser {
    if (getCurrentUser(ctx)) |u| return u;

    const token_value = ctx.attributes.get("token_value") orelse return null;
    if (!std.mem.startsWith(u8, token_value, "mul_")) return null;

    const hash = try auth.hashToken(ctx.allocator, token_value);
    defer ctx.allocator.free(hash);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT t.user_id, u.email FROM personal_access_token t " ++
                "JOIN \"user\" u ON u.id = t.user_id " ++
                "WHERE t.token_hash = $1 AND t.revoked = false " ++
                "AND (t.expires_at IS NULL OR t.expires_at > now())",
            &[_]SqlParam{.{ .text = hash }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        const uid = rs.rows.items[0].getText(0) orelse return null;
        const email = rs.rows.items[0].getText(1) orelse return null;
        return .{ .id = try ctx.allocator.dupe(u8, uid), .email = try ctx.allocator.dupe(u8, email) };
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const id = mem_hashes.?.get(hash) orelse return null;
        const entry = mem_tokens.?.get(id) orelse return null;
        if (entry.revoked) return null;
        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        if (entry.expires_at) |exp| if (exp < now) return null;
        return .{ .id = try ctx.allocator.dupe(u8, entry.user_id), .email = try ctx.allocator.dupe(u8, entry.email) };
    }
}

// ──────────────────────────────────────────────────────────────────────
// list
// ──────────────────────────────────────────────────────────────────────

pub fn listTokens(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = (try resolveCaller(ctx)) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    defer allocator.free(u.id);
    defer allocator.free(u.email);

    var list: std.ArrayList(model.PatResponse) = .empty;
    defer {
        for (list.items) |it| {
            if (it.expires_at) |e| allocator.free(e);
            if (it.last_used_at) |e| allocator.free(e);
            allocator.free(it.created_at);
            allocator.free(it.id);
            allocator.free(it.name);
            allocator.free(it.token_prefix);
        }
        list.deinit(allocator);
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, name, token_prefix, expires_at, last_used_at, created_at " ++
                "FROM personal_access_token WHERE user_id = $1 AND revoked = false " ++
                "ORDER BY created_at DESC",
            &[_]SqlParam{.{ .text = u.id }},
        );
        defer rs.deinit();

        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            const id = try allocator.dupe(u8, r.getText(0) orelse "");
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, r.getText(1) orelse "");
            errdefer allocator.free(name);
            const token_prefix = try allocator.dupe(u8, r.getText(2) orelse "");
            errdefer allocator.free(token_prefix);
            const expires = if (r.getText(3)) |s| try allocator.dupe(u8, s) else null;
            errdefer if (expires) |e| allocator.free(e);
            const last_used = if (r.getText(4)) |s| try allocator.dupe(u8, s) else null;
            errdefer if (last_used) |e| allocator.free(e);
            const created = if (r.getText(5)) |s| try allocator.dupe(u8, s) else "";
            errdefer allocator.free(created);
            try list.append(allocator, .{
                .id = id,
                .name = name,
                .token_prefix = token_prefix,
                .expires_at = expires,
                .last_used_at = last_used,
                .created_at = created,
            });
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        var it = mem_tokens.?.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.value_ptr.user_id, u.id)) continue;
            if (e.value_ptr.revoked) continue;
            const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
            if (e.value_ptr.expires_at) |exp| if (exp < now) continue;
            try list.append(allocator, .{
                .id = e.key_ptr.*,
                .name = e.value_ptr.name,
                .token_prefix = e.value_ptr.token_prefix,
                .expires_at = try model.optionalTimestamp(allocator, e.value_ptr.expires_at),
                .last_used_at = try model.optionalTimestamp(allocator, e.value_ptr.last_used_at),
                .created_at = try model.rfc3339(allocator, e.value_ptr.created_at),
            });
        }
    }

    try ctx.renderJson(list.items);
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = (try resolveCaller(ctx)) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    defer allocator.free(u.id);
    defer allocator.free(u.email);

    const parsed = try ctx.parseJsonBody(model.CreatePatRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }

    const raw_token = try auth.generatePersonalAccessToken(allocator);
    defer allocator.free(raw_token);
    const prefix = raw_token[0..@min(12, raw_token.len)];
    const hash = try auth.hashToken(allocator, raw_token);
    defer allocator.free(hash);

    const expires_param: ?[]const u8 = if (req.expires_in_days) |days| blk: {
        if (days > 0) {
            const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
            break :blk try model.rfc3339(allocator, now + @as(i64, days) * 24 * 60 * 60);
        }
        break :blk null;
    } else null;
    defer if (expires_param) |e| allocator.free(e);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const params = [_]SqlParam{
            .{ .text = u.id },
            .{ .text = name },
            .{ .text = hash },
            .{ .text = prefix },
            .{ .text = expires_param orelse "" },
        };
        var rs = db.queryParams(
            "INSERT INTO personal_access_token (user_id, name, token_hash, token_prefix, expires_at) " ++
                "VALUES ($1, $2, $3, $4, CASE WHEN $5 = '' THEN NULL ELSE $5::timestamptz END) " ++
                "RETURNING id, name, token_prefix, expires_at, last_used_at, created_at",
            &params,
        ) catch |err| {
            log.err("create token failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create token" });
            return;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create token" });
            return;
        }
        const r0 = &rs.rows.items[0];

        const pat_id = try allocator.dupe(u8, r0.getText(0) orelse "");
        errdefer allocator.free(pat_id);
        const pat_name = try allocator.dupe(u8, r0.getText(1) orelse "");
        errdefer allocator.free(pat_name);
        const pat_token_prefix = try allocator.dupe(u8, r0.getText(2) orelse "");
        errdefer allocator.free(pat_token_prefix);
        const expires = if (r0.getText(3)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (expires) |e| allocator.free(e);
        const last_used = if (r0.getText(4)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (last_used) |e| allocator.free(e);
        const created = if (r0.getText(5)) |s| try allocator.dupe(u8, s) else "";
        errdefer allocator.free(created);

        ctx.res_status = .created;
        try ctx.renderJson(model.CreatePatResponse{
            .id = pat_id,
            .name = pat_name,
            .token_prefix = pat_token_prefix,
            .expires_at = expires,
            .last_used_at = last_used,
            .created_at = created,
            .token = raw_token,
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = try memGenerateId();
        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        var exp: ?i64 = null;
        if (req.expires_in_days) |days| {
            if (days > 0) {
                exp = now + @as(i64, days) * 24 * 60 * 60;
            }
        }
        const entry = model.PatEntry{
            .id = id,
            .user_id = try memDup(u.id),
            .email = try memDup(u.email),
            .name = try memDup(name),
            .token_hash = try memDup(hash),
            .token_prefix = try memDup(prefix),
            .expires_at = exp,
            .last_used_at = null,
            .created_at = now,
            .revoked = false,
        };
        try mem_tokens.?.put(id, entry);
        try mem_hashes.?.put(entry.token_hash, id);

        ctx.res_status = .created;
        try ctx.renderJson(model.CreatePatResponse{
            .id = entry.id,
            .name = entry.name,
            .token_prefix = entry.token_prefix,
            .expires_at = try model.optionalTimestamp(allocator, entry.expires_at),
            .last_used_at = null,
            .created_at = try model.rfc3339(allocator, entry.created_at),
            .token = raw_token,
        });
    }
}

// ──────────────────────────────────────────────────────────────────────
// renew
// ──────────────────────────────────────────────────────────────────────

pub fn renewCurrentToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    const auth_header = ctx.getHeader("Authorization") orelse "";
    const bearer_prefix = "Bearer ";
    const raw_token = if (std.mem.startsWith(u8, auth_header, bearer_prefix))
        std.mem.trim(u8, auth_header[bearer_prefix.len..], &std.ascii.whitespace)
    else
        "";

    if (raw_token.len == 0 or !std.mem.startsWith(u8, raw_token, "mul_")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "only personal access tokens can be renewed" });
        return;
    }

    const hash = try auth.hashToken(allocator, raw_token);
    defer allocator.free(hash);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var lookup = try db.queryParams(
            "SELECT id, user_id, expires_at, " ++
                "expires_at IS NULL AS no_expiry, " ++
                "COALESCE(expires_at > now() + interval '7 days', false) AS far_future " ++
                "FROM personal_access_token WHERE token_hash = $1 AND revoked = false",
            &[_]SqlParam{.{ .text = hash }},
        );
        defer lookup.deinit();

        if (lookup.rows.items.len == 0) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token is no longer valid" });
            return;
        }
        const lk0 = &lookup.rows.items[0];

        const user_id = lk0.getText(1) orelse "";
        const u = getCurrentUser(ctx);
        if (u != null and !std.mem.eql(u8, u.?.id, user_id)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token does not belong to caller" });
            return;
        }

        const no_expiry = model.parseBool(lk0.getText(3), false);
        if (no_expiry) {
            try ctx.renderJson(model.RenewPatResponse{ .expires_at = "", .renewed = false });
            return;
        }

        const expires_text_raw = lk0.getText(2) orelse "";
        const far_future = model.parseBool(lk0.getText(4), false);
        if (far_future) {
            const expires_text = try allocator.dupe(u8, expires_text_raw);
            defer allocator.free(expires_text);
            try ctx.renderJson(model.RenewPatResponse{ .expires_at = expires_text, .renewed = false });
            return;
        }

        const id = lk0.getText(0) orelse "";
        var rs = db.queryParams(
            "UPDATE personal_access_token SET expires_at = now() + interval '90 days' " ++
                "WHERE id = $1 AND revoked = false AND expires_at IS NOT NULL AND expires_at <= now() + interval '7 days' " ++
                "RETURNING expires_at",
            &[_]SqlParam{.{ .text = id }},
        ) catch |err| {
            log.err("renew token failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to renew token" });
            return;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            // Lost the race; re-read current row.
            var current = try db.queryParams(
                "SELECT expires_at FROM personal_access_token WHERE token_hash = $1 AND revoked = false",
                &[_]SqlParam{.{ .text = hash }},
            );
            defer current.deinit();
            if (current.rows.items.len == 0) {
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .@"error" = "token is no longer valid" });
                return;
            }
            const cur_exp_raw = current.rows.items[0].getText(0) orelse "";
            const cur_exp = try allocator.dupe(u8, cur_exp_raw);
            defer allocator.free(cur_exp);
            try ctx.renderJson(model.RenewPatResponse{ .expires_at = cur_exp, .renewed = false });
            return;
        }

        const returned_raw = rs.rows.items[0].getText(0) orelse expires_text_raw;
        const returned = try allocator.dupe(u8, returned_raw);
        defer allocator.free(returned);
        try ctx.renderJson(model.RenewPatResponse{ .expires_at = returned, .renewed = true });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = mem_hashes.?.get(hash) orelse {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token is no longer valid" });
            return;
        };
        const entry = mem_tokens.?.getPtr(id) orelse {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token is no longer valid" });
            return;
        };
        if (entry.revoked) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token is no longer valid" });
            return;
        }

        const u = getCurrentUser(ctx);
        if (u != null and !std.mem.eql(u8, u.?.id, entry.user_id)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "token does not belong to caller" });
            return;
        }

        if (entry.expires_at == null) {
            try ctx.renderJson(model.RenewPatResponse{ .expires_at = "", .renewed = false });
            return;
        }

        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const renew_threshold = 7 * 24 * 60 * 60;
        if (entry.expires_at.? - now > renew_threshold) {
            try ctx.renderJson(model.RenewPatResponse{ .expires_at = try model.rfc3339(allocator, entry.expires_at.?), .renewed = false });
            return;
        }

        entry.expires_at = now + 90 * 24 * 60 * 60;
        try ctx.renderJson(model.RenewPatResponse{ .expires_at = try model.rfc3339(allocator, entry.expires_at.?), .renewed = true });
    }
}

// ──────────────────────────────────────────────────────────────────────
// revoke
// ──────────────────────────────────────────────────────────────────────

pub fn revokeToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = (try resolveCaller(ctx)) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    defer allocator.free(u.id);
    defer allocator.free(u.email);

    const id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_token_id" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        _ = db.queryParams(
            "UPDATE personal_access_token SET revoked = true " ++
                "WHERE id = $1 AND user_id = $2 RETURNING token_hash",
            &[_]SqlParam{
                .{ .text = id },
                .{ .text = u.id },
            },
        ) catch |err| {
            log.err("revoke token failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to revoke token" });
            return;
        };
        // Idempotent: 204 regardless of whether row existed.
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_tokens.?.getPtr(id) orelse {
            try response.okNoContent(ctx);
            return;
        };
        if (!std.mem.eql(u8, entry.user_id, u.id)) {
            try response.okNoContent(ctx);
            return;
        }
        entry.revoked = true;
    }

    try response.okNoContent(ctx);
return;
}