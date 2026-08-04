//! Notification preference module — business logic.
//!
//! Owns the per-process state (`g_prefs`) and exposes the two
//! HTTP-facing operations: `getPreferences`, `updatePreferences`. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");

const log = std.log.scoped(.notification_pref_service);

var g_prefs: model.PreferencesResponse = model.default_prefs;

pub fn init(_: *const anyopaque) void {}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

pub fn getPreferences(ctx: *zfinal.Context) !void {
    if (getWorkspaceId(ctx)) |workspace_id| {
        if (getUserId(ctx)) |user_id| {
            if (try model.readFromDb(ctx.allocator, workspace_id, user_id)) |row| {
                try ctx.renderJson(row);
                return;
            }
        }
    }
    try ctx.renderJson(g_prefs);
}

pub fn updatePreferences(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(model.PreferencesRequest);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.email_digest) |v| g_prefs.email_digest = v;
    if (req.email_mentions) |v| g_prefs.email_mentions = v;
    if (req.email_task_updates) |v| g_prefs.email_task_updates = v;
    if (req.push_mentions) |v| g_prefs.push_mentions = v;
    if (req.push_task_updates) |v| g_prefs.push_task_updates = v;

    if (getWorkspaceId(ctx)) |workspace_id| {
        if (getUserId(ctx)) |user_id| {
            model.writeToDb(ctx.allocator, workspace_id, user_id, g_prefs) catch {};
        }
    }
    try ctx.renderJson(g_prefs);
}