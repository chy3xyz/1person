//! User module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response + request DTOs), the
//! escape-hatch SQL helpers, and the heavy row → response projector.
//! `service.zig` wraps this with the business logic, the in-memory
//! state (`mem_users`, `mem_feedback`), and the no-DB fallback path.
//!
//! The `user` row has UUID PKs, JSONB columns
//! (`onboarding_questionnaire`, `starter_content_state`), and
//! nullable profile fields, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`. The smoke test exercises
//! the in-memory fallback when the DB is unconfigured.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised. Callers own the
/// `defer deps.releaseBack(db)`.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

/// Request body for `PATCH /api/me`.
pub const UpdateMeRequest = struct {
    name: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
    language: ?[]const u8 = null,
    profile_description: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
};

/// Request body for `POST /api/me/onboarding/cloud-waitlist`.
pub const CloudWaitlistRequest = struct {
    email: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

/// Request body for `POST /api/feedback`.
pub const FeedbackRequest = struct {
    message: []const u8,
    category: ?[]const u8 = null,
};

// ──────────────────────────────────────────────────────────────────────
// in-memory row structs
// ──────────────────────────────────────────────────────────────────────

/// In-memory `user` row — used by the no-DB fallback.
pub const UserState = struct {
    name: []const u8,
    avatar_url: []const u8,
    language: []const u8,
    timezone: []const u8,
    profile_description: []const u8,
    onboarded_at: []const u8,
    onboarding_questionnaire: std.json.Value,
    cloud_waitlist_email: []const u8,
    cloud_waitlist_reason: []const u8,
    starter_content_state: []const u8,
    runtime_bootstrap: []const u8,
};

/// In-memory `feedback` entry — used by the no-DB fallback.
pub const FeedbackEntry = struct {
    id: []const u8,
    user_id: []const u8,
    message: []const u8,
    category: []const u8,
    created_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// response DTO
// ──────────────────────────────────────────────────────────────────────

/// `user` row, projected for the API (used by both DB and in-memory
/// paths so the smoke test exercises the same wire shape).
pub const UserResponse = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    avatar_url: ?[]const u8,
    language: ?[]const u8,
    timezone: ?[]const u8,
    onboarded_at: ?[]const u8,
    onboarding_questionnaire: ?std.json.Value,
    starter_content_state: ?[]const u8,
    profile_description: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// pure helpers
// ──────────────────────────────────────────────────────────────────────

/// Page allocator used by the in-memory fallback. Lives in
/// process scope because the data is intentionally non-collected.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Best-effort, never-fail `dupe` over the page allocator. Caller
/// owns the returned slice.
pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

/// Unix-seconds string used for fake timestamps in the in-memory
/// store. Matches the format the DB would return for
/// `to_timestamp($n::bigint)` columns.
pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

/// Stable pseudo-UUID for the in-memory store.
pub fn memGenerateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

/// Empty JSON object literal — used when a JSONB column reads as NULL.
pub fn emptyJsonObject(_allocator: std.mem.Allocator) std.json.Value {
    _ = _allocator;
    return .{ .object = std.json.ObjectMap.empty };
}

/// Parse a JSON text blob, returning the value on success and `null`
/// on failure. The caller is responsible for any arena lifetime
/// management.
pub fn parseQuestionnaire(allocator: std.mem.Allocator, text: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    return parsed.value;
}

const supported_languages = [_][]const u8{ "en", "zh-Hans", "ko", "ja" };

/// Whitelist of accepted language tags for the `PATCH /api/me` body.
pub fn isSupportedLanguage(lang: []const u8) bool {
    for (supported_languages) |l| {
        if (std.mem.eql(u8, l, lang)) return true;
    }
    return false;
}

/// UTF-8 codepoint count. Used to enforce the
/// `profile_description` length cap (2000 codepoints).
pub fn runeCount(s: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(s);
}

// ──────────────────────────────────────────────────────────────────────
// row / state → response converters
// ──────────────────────────────────────────────────────────────────────

/// Project a `SELECT id, name, email, avatar_url, language, timezone,
/// onboarded_at, onboarding_questionnaire, starter_content_state,
/// profile_description, created_at, updated_at FROM "user"` row to
/// the API response shape. `onboarding_parsed` is the holder that
/// owns the parsed `std.json.Value` for `onboarding_questionnaire` —
/// the caller must `defer` the `deinit()` because the returned
/// `UserResponse` references its `arena`.
pub fn userResponseFromRow(allocator: std.mem.Allocator, rs: zfinal.ResultSet, row: usize) !UserResponse {
    var onboarding_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (onboarding_parsed) |p| p.deinit();
    const r = &rs.rows.items[row];
    const onboarding_text = r.getText(7) orelse "{}";
    onboarding_parsed = std.json.parseFromSlice(std.json.Value, allocator, onboarding_text, .{}) catch null;
    return UserResponse{
        .id = r.getText(0) orelse "",
        .name = r.getText(1) orelse "",
        .email = r.getText(2) orelse "",
        .avatar_url = r.getText(3),
        .language = r.getText(4),
        .timezone = r.getText(5),
        .onboarded_at = r.getText(6),
        .onboarding_questionnaire = if (onboarding_parsed) |p| p.value else null,
        .starter_content_state = r.getText(8),
        .profile_description = r.getText(9),
        .created_at = r.getText(10) orelse "",
        .updated_at = r.getText(11) orelse "",
    };
}

/// Project an in-memory `UserState` to the API response shape. Used
/// by the no-DB smoke path. `onboarding_parsed` is the holder that
/// owns the parsed `std.json.Value` for `onboarding_questionnaire` —
/// the caller must `defer` the `deinit()` because the returned
/// `UserResponse` references its `arena`.
pub fn userResponseFromState(allocator: std.mem.Allocator, user_id: []const u8, email: []const u8, state: UserState) !UserResponse {
    var onboarding_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (onboarding_parsed) |p| p.deinit();
    const q_text = try std.json.Stringify.valueAlloc(allocator, state.onboarding_questionnaire, .{});
    defer allocator.free(q_text);
    onboarding_parsed = std.json.parseFromSlice(std.json.Value, allocator, q_text, .{}) catch null;
    return UserResponse{
        .id = user_id,
        .name = if (state.name.len > 0) state.name else email,
        .email = email,
        .avatar_url = if (state.avatar_url.len > 0) state.avatar_url else null,
        .language = if (state.language.len > 0) state.language else null,
        .timezone = if (state.timezone.len > 0) state.timezone else null,
        .onboarded_at = if (state.onboarded_at.len > 0) state.onboarded_at else null,
        .onboarding_questionnaire = if (onboarding_parsed) |p| p.value else null,
        .starter_content_state = if (state.starter_content_state.len > 0) state.starter_content_state else null,
        .profile_description = if (state.profile_description.len > 0) state.profile_description else null,
        .created_at = "",
        .updated_at = "",
    };
}
