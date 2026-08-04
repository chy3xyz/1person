//! Workspace module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.
//!
//! The trailing `pub const` aliases re-export the public data
//! surface that `src/modules/invitation/service.zig` and
//! `src/modules/realtime/service.zig` import. The legacy import
//! (`@import("../../handlers/workspace.zig")`) is being retired in
//! the same turn, so the sibling modules are updated to point at
//! `../workspace/service.zig` instead. Keeping the aliases here as
//! well means a downstream consumer can still reach the types
//! through `modules/workspace/handler.zig` if it prefers that
//! surface.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");
const model = @import("model.zig");

pub fn init(cfg: *const Config) void {
    service.init(cfg);
}

// ──────────────────────────────────────────────────────────────────────
// HTTP-facing delegates (one per route)
// ──────────────────────────────────────────────────────────────────────

pub fn listWorkspaces(ctx: *zfinal.Context) !void {
    try service.listWorkspaces(ctx);
}

pub fn createWorkspace(ctx: *zfinal.Context) !void {
    try service.createWorkspace(ctx);
}

pub fn getWorkspace(ctx: *zfinal.Context) !void {
    try service.getWorkspace(ctx);
}

pub fn updateWorkspace(ctx: *zfinal.Context) !void {
    try service.updateWorkspace(ctx);
}

pub fn deleteWorkspace(ctx: *zfinal.Context) !void {
    try service.deleteWorkspace(ctx);
}

pub fn listMembers(ctx: *zfinal.Context) !void {
    try service.listMembers(ctx);
}

pub fn addMember(ctx: *zfinal.Context) !void {
    try service.addMember(ctx);
}

pub fn updateMemberRole(ctx: *zfinal.Context) !void {
    try service.updateMemberRole(ctx);
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    try service.removeMember(ctx);
}

pub fn leaveWorkspace(ctx: *zfinal.Context) !void {
    try service.leaveWorkspace(ctx);
}

pub fn listInvitations(ctx: *zfinal.Context) !void {
    try service.listInvitations(ctx);
}

pub fn createInvitation(ctx: *zfinal.Context) !void {
    try service.createInvitation(ctx);
}

pub fn deleteInvitation(ctx: *zfinal.Context) !void {
    try service.deleteInvitation(ctx);
}

pub fn listGithubInstallations(ctx: *zfinal.Context) !void {
    try service.listGithubInstallations(ctx);
}

pub fn connectGithub(ctx: *zfinal.Context) !void {
    try service.connectGithub(ctx);
}

pub fn connectGithubInstallation(ctx: *zfinal.Context) !void {
    try service.connectGithubInstallation(ctx);
}

pub fn deleteGithubInstallation(ctx: *zfinal.Context) !void {
    try service.deleteGithubInstallation(ctx);
}

pub fn listLarkInstallations(ctx: *zfinal.Context) !void {
    try service.listLarkInstallations(ctx);
}

pub fn connectLark(ctx: *zfinal.Context) !void {
    try service.connectLark(ctx);
}

pub fn deleteLarkInstallation(ctx: *zfinal.Context) !void {
    try service.deleteLarkInstallation(ctx);
}

pub fn beginLarkInstall(ctx: *zfinal.Context) !void {
    try service.beginLarkInstall(ctx);
}

pub fn getLarkInstallStatus(ctx: *zfinal.Context) !void {
    try service.getLarkInstallStatus(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// multi-tenancy V2 delegates
// ──────────────────────────────────────────────────────────────────────

pub fn createChildWorkspace(ctx: *zfinal.Context) !void {
    try service.createChildWorkspace(ctx);
}

pub fn getChildren(ctx: *zfinal.Context) !void {
    try service.getChildren(ctx);
}

pub fn getWorkspaceTree(ctx: *zfinal.Context) !void {
    try service.getWorkspaceTree(ctx);
}

pub fn setLimit(ctx: *zfinal.Context) !void {
    try service.setLimit(ctx);
}

pub fn getLimit(ctx: *zfinal.Context) !void {
    try service.getLimit(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// Cross-module public surface.
// ──────────────────────────────────────────────────────────────────────
//
// `src/modules/invitation/service.zig` and
// `src/modules/realtime/service.zig` previously reached into
// `src/handlers/workspace.zig` for these symbols. They now import
// `../workspace/service.zig` directly, but the re-exports below keep
// the handler-side public surface identical so a third-party caller
// can still discover the types through `modules/workspace/handler.zig`.

pub const WorkspaceEntry = model.WorkspaceEntry;
pub const MemberEntry = model.MemberEntry;
pub const InvitationEntry = model.InvitationEntry;
pub const WorkspaceResponse = model.WorkspaceResponse;
pub const MemberResponse = model.MemberResponse;
pub const InvitationResponse = model.InvitationResponse;

/// `memAddMember(workspace_id, user_id, role, name, email)` — append
/// a member row to the in-memory fallback store. Mirrors the legacy
/// `src/handlers/workspace.zig` export consumed by
/// `src/modules/invitation/service.zig::acceptInvitation`.
pub fn memAddMember(workspace_id: []const u8, user_id: []const u8, role: []const u8, name: []const u8, email: []const u8) !void {
    try model.memAddMember(workspace_id, user_id, role, name, email);
}

/// `memGetWorkspaceName(workspace_id)` — best-effort lookup of the
/// workspace display name from the in-memory fallback store. Mirrors
/// the legacy `src/handlers/workspace.zig` export consumed by
/// `src/modules/invitation/service.zig`.
pub fn memGetWorkspaceName(workspace_id: []const u8) ?[]const u8 {
    return model.memGetWorkspaceName(workspace_id);
}

/// `resolveSlug(allocator, slug)` — DB-or-mem slug → id resolution.
/// Mirrors the legacy `src/handlers/workspace.zig` export consumed
/// by `src/modules/realtime/service.zig::resolveWorkspace`.
pub fn resolveSlug(allocator: std.mem.Allocator, slug: []const u8) ?[]const u8 {
    return model.resolveSlug(allocator, slug);
}
