//! Shared request-context helpers, extracted from the per-module copies
//! of `getWorkspaceId` / `getUserId`.

const zfinal = @import("zfinal");

/// Resolve the workspace id stamped by `RequireWorkspaceMember`.
/// Accepts both the canonical `workspace_id` attribute and the legacy
/// `X-Workspace-Id` casing some modules used.
pub fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id") orelse
        ctx.attributes.get("X-Workspace-Id") orelse
        null;
}

/// Resolve the authenticated user id.
pub fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}
