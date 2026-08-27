//! User module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_users`
//! and `mem_feedback` tables) and exposes the ten HTTP-facing
//! operations: `getMe`, `meMarker`, `updateMe`, `patchOnboarding`,
//! `completeOnboarding`, `cloudWaitlist`, `runtimeBootstrap`,
//! `noRuntimeBootstrap`, `createCliToken`, `submitFeedback`. The
//! `handler.zig` is a thin delegate; data shapes and the heavy
//! `userResponseFromRow` projector live in `model.zig`.
//!
//! The DB access goes through `deps.acquire()` + `zfinal.DB` +
//! `zfinal.SqlParam` directly (Pattern 3 of
//! `HANDLER_MIGRATION_GUIDE.md`). The no-DB fallback mutates the
//! in-memory `UserState` and `FeedbackEntry` records guarded by
//! `mem_mutex` — this path is exercised by the smoke test.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");

const log = std.log.scoped(.user_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// in-memory state
// ──────────────────────────────────────────────────────────────────────

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_users: ?std.StringHashMap(model.UserState) = null;
var mem_feedback: ?std.StringHashMap(std.ArrayList(model.FeedbackEntry)) = null;

fn memInit() !void {
    if (mem_users == null) {
        mem_users = std.StringHashMap(model.UserState).init(model.memAlloc());
    }
}

fn userStateFor(user_id: []const u8) !*model.UserState {
    try memInit();
    const gop = try mem_users.?.getOrPut(user_id);
    if (!gop.found_existing) {
        gop.key_ptr.* = try model.memDup(user_id);
        gop.value_ptr.* = model.UserState{
            .name = try model.memDup(""),
            .avatar_url = try model.memDup(""),
            .language = try model.memDup(""),
            .timezone = try model.memDup(""),
            .profile_description = try model.memDup(""),
            .onboarded_at = try model.memDup(""),
            .onboarding_questionnaire = .{ .object = std.json.ObjectMap.empty },
            .cloud_waitlist_email = try model.memDup(""),
            .cloud_waitlist_reason = try model.memDup(""),
            .starter_content_state = try model.memDup(""),
            .runtime_bootstrap = try model.memDup(""),
        };
    }
    return gop.value_ptr;
}

fn ensureFeedback() !void {
    if (mem_feedback == null) {
        mem_feedback = std.StringHashMap(std.ArrayList(model.FeedbackEntry)).init(model.memAlloc());
    }
}

fn storeFeedback(user_id: []const u8, message: []const u8, category: ?[]const u8) !void {
    try ensureFeedback();
    const now = try model.nowString();
    const id = try model.memGenerateId(model.memAlloc(), "feedback");
    const entry = model.FeedbackEntry{
        .id = id,
        .user_id = try model.memDup(user_id),
        .message = try model.memDup(message),
        .category = try model.memDup(category orelse ""),
        .created_at = try model.memDup(now),
    };
    var list = mem_feedback.?.get(user_id) orelse std.ArrayList(model.FeedbackEntry).empty;
    try list.append(model.memAlloc(), entry);
    try mem_feedback.?.put(try model.memDup(user_id), list);
}

// ──────────────────────────────────────────────────────────────────────
// context helpers
// ──────────────────────────────────────────────────────────────────────

fn getCurrentUser(ctx: *zfinal.Context) ?struct { id: []const u8, email: []const u8 } {
    const id = ctx.attributes.get("user_id") orelse return null;
    const email = ctx.attributes.get("email") orelse return null;
    return .{ .id = id, .email = email };
}

// ──────────────────────────────────────────────────────────────────────
// getMe / meMarker
// ──────────────────────────────────────────────────────────────────────

pub fn getMe(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    var onboarding_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (onboarding_parsed) |p| p.deinit();

    // NOTE: the response borrows string slices straight out of the
    // ResultSet, so `renderJson` must run while `rs` is still alive.
    // Building the struct and rendering after the block exits reads
    // freed memory.
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = try db.queryParams(
            "SELECT id::text, name, email, avatar_url, language, timezone, onboarded_at, " ++
                "onboarding_questionnaire::text, starter_content_state, profile_description, " ++
                "created_at, updated_at FROM \"user\" WHERE id = $1",
            &[_]SqlParam{.{ .text = u.id }},
        );
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "user_not_found" });
            return;
        }

        const r0 = &rs.rows.items[0];
        const onboarding_text = r0.getText(7) orelse "{}";
        onboarding_parsed = std.json.parseFromSlice(std.json.Value, allocator, onboarding_text, .{}) catch null;

        try ctx.renderJson(model.UserResponse{
            .id = r0.getText(0) orelse u.id,
            .name = r0.getText(1) orelse "",
            .email = r0.getText(2) orelse u.email,
            .avatar_url = r0.getText(3),
            .language = r0.getText(4),
            .timezone = r0.getText(5),
            .onboarded_at = r0.getText(6),
            .onboarding_questionnaire = if (onboarding_parsed) |p| p.value else null,
            .starter_content_state = r0.getText(8),
            .profile_description = r0.getText(9),
            .created_at = r0.getText(10) orelse "",
            .updated_at = r0.getText(11) orelse "",
        });
    } else {
        const resp = resp: {
            try mem_mutex.lock(zfinal.io_instance.io);
            defer mem_mutex.unlock(zfinal.io_instance.io);
            const state = try userStateFor(u.id);
            break :resp try model.userResponseFromState(allocator, u.id, u.email, state.*);
        };
        try ctx.renderJson(resp);
    }
}

pub fn meMarker(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .marker = true });
}

// ──────────────────────────────────────────────────────────────────────
// updateMe
// ──────────────────────────────────────────────────────────────────────

pub fn updateMe(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateMeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = if (req.name) |n| blk: {
        const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name_required" });
            return;
        }
        break :blk trimmed;
    } else null;

    const avatar_url = if (req.avatar_url) |u_| std.mem.trim(u8, u_, &std.ascii.whitespace) else null;

    const language = if (req.language) |l| blk: {
        const trimmed = std.mem.trim(u8, l, &std.ascii.whitespace);
        if (!model.isSupportedLanguage(trimmed)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "unsupported_language" });
            return;
        }
        break :blk trimmed;
    } else null;

    const profile_description = if (req.profile_description) |pd| blk: {
        const trimmed = std.mem.trim(u8, pd, &std.ascii.whitespace);
        if (model.runeCount(trimmed) catch 0 > 2000) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "profile_description_too_long" });
            return;
        }
        break :blk trimmed;
    } else null;

    const timezone = if (req.timezone) |tz| std.mem.trim(u8, tz, &std.ascii.whitespace) else null;

    var onboarding_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (onboarding_parsed) |p| p.deinit();

    // NOTE: see getMe — the response borrows slices owned by `rs`, so
    // rendering must happen before the ResultSet is deinit'd.
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const params = [_]SqlParam{
            .{ .text = u.id },
            .{ .text = name orelse "" },
            .{ .text = avatar_url orelse "" },
            .{ .text = language orelse "" },
            .{ .text = profile_description orelse "" },
            .{ .text = timezone orelse "" },
        };
        var rs = try db.queryParams(
            "UPDATE \"user\" SET " ++
                "name = COALESCE(NULLIF($2, ''), name), " ++
                "avatar_url = COALESCE(NULLIF($3, ''), avatar_url), " ++
                "language = COALESCE(NULLIF($4, ''), language), " ++
                "profile_description = COALESCE(NULLIF($5, ''), profile_description), " ++
                // $6 needs an explicit cast: `IS NULL` / `= ''` give the
                // planner no type to infer from (SQLSTATE 42P08).
                "timezone = CASE WHEN $6::text IS NULL THEN timezone WHEN $6::text = '' THEN NULL ELSE $6::text END, " ++
                "updated_at = now() " ++
                "WHERE id = $1 " ++
                "RETURNING id::text, name, email, avatar_url, language, timezone, onboarded_at, " ++
                "onboarding_questionnaire::text, starter_content_state, profile_description, created_at, updated_at",
            &params,
        );
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "user_not_found" });
            return;
        }

        const r0 = &rs.rows.items[0];
        const onboarding_text = r0.getText(7) orelse "{}";
        onboarding_parsed = std.json.parseFromSlice(std.json.Value, allocator, onboarding_text, .{}) catch null;

        try ctx.renderJson(model.UserResponse{
            .id = r0.getText(0) orelse u.id,
            .name = r0.getText(1) orelse "",
            .email = r0.getText(2) orelse u.email,
            .avatar_url = r0.getText(3),
            .language = r0.getText(4),
            .timezone = r0.getText(5),
            .onboarded_at = r0.getText(6),
            .onboarding_questionnaire = if (onboarding_parsed) |p| p.value else null,
            .starter_content_state = r0.getText(8),
            .profile_description = r0.getText(9),
            .created_at = r0.getText(10) orelse "",
            .updated_at = r0.getText(11) orelse "",
        });
    } else {
        const resp = resp: {
            try mem_mutex.lock(zfinal.io_instance.io);
            defer mem_mutex.unlock(zfinal.io_instance.io);
            const state = try userStateFor(u.id);
            if (name) |n| state.name = try model.memDup(n);
            if (avatar_url) |a| state.avatar_url = try model.memDup(a);
            if (language) |l| state.language = try model.memDup(l);
            if (profile_description) |pd| state.profile_description = try model.memDup(pd);
            if (timezone) |tz| state.timezone = try model.memDup(tz);

            onboarding_parsed = std.json.parseFromSlice(std.json.Value, allocator, "{}", .{}) catch null;
            break :resp try model.userResponseFromState(allocator, u.id, name orelse u.email, state.*);
        };
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// onboarding sub-routes
// ──────────────────────────────────────────────────────────────────────

pub fn patchOnboarding(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const text = try std.json.Stringify.valueAlloc(ctx.allocator, parsed.value, .{});
        defer ctx.allocator.free(text);
        const params = [_]SqlParam{
            .{ .text = u.id },
            .{ .text = text },
        };
        _ = try db.queryParams(
            "UPDATE \"user\" SET onboarding_questionnaire = $2::jsonb, updated_at = now() WHERE id = $1::uuid RETURNING id",
            &params,
        );
    } else {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const state = try userStateFor(u.id);
        state.onboarding_questionnaire = parsed.value;
    }

    try ctx.renderJson(.{ .success = true, .questionnaire = parsed.value });
}

pub fn completeOnboarding(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const now = try model.nowString();
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const params = [_]SqlParam{
            .{ .text = u.id },
            .{ .text = now },
            .{ .text = "{\"onboarded\":true}" },
        };
        _ = try db.queryParams(
            "UPDATE \"user\" SET onboarded_at = to_timestamp($2::bigint), starter_content_state = $3::jsonb, updated_at = now() " ++
                "WHERE id = $1::uuid RETURNING id",
            &params,
        );
    } else {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const state = try userStateFor(u.id);
        state.onboarded_at = try model.memDup(now);
        state.starter_content_state = try model.memDup("{\"onboarded\":true}");
    }

    try ctx.renderJson(.{ .success = true, .onboarded_at = now });
}

pub fn cloudWaitlist(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.CloudWaitlistRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const email = std.mem.trim(u8, req.email orelse "", &std.ascii.whitespace);
    const reason = std.mem.trim(u8, req.reason orelse "", &std.ascii.whitespace);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const params = [_]SqlParam{
            .{ .text = u.id },
            .{ .text = email },
            .{ .text = reason },
        };
        _ = try db.queryParams(
            "UPDATE \"user\" SET cloud_waitlist_email = $2, cloud_waitlist_reason = $3, updated_at = now() " ++
                "WHERE id = $1::uuid RETURNING id",
            &params,
        );
    } else {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const state = try userStateFor(u.id);
        state.cloud_waitlist_email = try model.memDup(email);
        state.cloud_waitlist_reason = try model.memDup(reason);
    }

    ctx.res_status = .accepted;
    try ctx.renderJson(.{ .success = true, .email = email, .reason = reason });
}

pub fn runtimeBootstrap(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        _ = try db.queryParams(
            "UPDATE \"user\" SET starter_content_state = '{\"runtime_bootstrapped\":true}'::jsonb, updated_at = now() " ++
                "WHERE id = $1::uuid RETURNING id",
            &[_]SqlParam{.{ .text = u.id }},
        );
    } else {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const state = try userStateFor(u.id);
        state.starter_content_state = try model.memDup("{\"runtime_bootstrapped\":true}");
    }

    try ctx.renderJson(.{ .success = true, .runtime_bootstrapped = true });
}

pub fn noRuntimeBootstrap(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        _ = try db.queryParams(
            "UPDATE \"user\" SET starter_content_state = '{\"runtime_skipped\":true}'::jsonb, updated_at = now() " ++
                "WHERE id = $1::uuid RETURNING id",
            &[_]SqlParam{.{ .text = u.id }},
        );
    } else {
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const state = try userStateFor(u.id);
        state.starter_content_state = try model.memDup("{\"runtime_skipped\":true}");
    }

    try ctx.renderJson(.{ .success = true, .runtime_skipped = true });
}

// ──────────────────────────────────────────────────────────────────────
// cli-token / feedback
// ──────────────────────────────────────────────────────────────────────

pub fn createCliToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const seed = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ u.id, ns });
    defer allocator.free(seed);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &hash, .{});
    var hex: [64]u8 = undefined;
    const charset = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    try ctx.renderJson(.{ .token = hex[0..], .user_id = u.id });
}

pub fn submitFeedback(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.FeedbackRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const message = std.mem.trim(u8, req.message, &std.ascii.whitespace);
    if (message.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "message is required" });
        return;
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try storeFeedback(u.id, message, req.category);
    const list = mem_feedback.?.get(u.id).?;
    const entry = list.items[list.items.len - 1];

    try ctx.renderJson(.{ .success = true, .id = entry.id });
}
