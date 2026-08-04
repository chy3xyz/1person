//! Role module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn init(cfg: *const Config) void {
    service.init(cfg);
}

// ── RoleConfig (definitions) ─────────────────────────────────────────

pub fn listRoleConfigs(ctx: *zfinal.Context) !void {
    try service.listRoleConfigs(ctx);
}

pub fn getRoleConfig(ctx: *zfinal.Context) !void {
    try service.getRoleConfig(ctx);
}

pub fn createRoleConfig(ctx: *zfinal.Context) !void {
    try service.createRoleConfig(ctx);
}

pub fn updateRoleConfig(ctx: *zfinal.Context) !void {
    try service.updateRoleConfig(ctx);
}

pub fn deleteRoleConfig(ctx: *zfinal.Context) !void {
    try service.deleteRoleConfig(ctx);
}

// ── MemberRole (assignments) ─────────────────────────────────────────

pub fn listMemberRoles(ctx: *zfinal.Context) !void {
    try service.listMemberRoles(ctx);
}

pub fn getMemberRole(ctx: *zfinal.Context) !void {
    try service.getMemberRole(ctx);
}

pub fn assignRole(ctx: *zfinal.Context) !void {
    try service.assignRole(ctx);
}

pub fn updateMemberRole(ctx: *zfinal.Context) !void {
    try service.updateMemberRole(ctx);
}

pub fn deleteMemberRole(ctx: *zfinal.Context) !void {
    try service.deleteMemberRole(ctx);
}

// ── Hierarchical queries ─────────────────────────────────────────────

pub fn getDownlineTree(ctx: *zfinal.Context) !void {
    try service.getDownlineTree(ctx);
}

pub fn getUplineChain(ctx: *zfinal.Context) !void {
    try service.getUplineChain(ctx);
}
