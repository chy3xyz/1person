//! Workspace resolution and role-check interceptor.
//!
//! Uses the process-wide `zfinal.ConnectionPool` in `deps.zig`; there
//! is no per-handler pool pointer to wire up. When `deps.pool` is
//! null (no DATABASE_URL configured) the middleware degrades to a
//! permissive "owner" stub so the no-DB smoke path keeps working.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../config.zig").Config;
const deps = @import("../deps.zig");

const log = std.log.scoped(.workspace_middleware);

var g_cfg: ?*const Config = null;

pub fn setConfig(cfg: *const Config) void {
    g_cfg = cfg;
}

fn roleRank(role: []const u8) u8 {
    if (std.mem.eql(u8, role, "owner")) return 3;
    if (std.mem.eql(u8, role, "admin")) return 2;
    if (std.mem.eql(u8, role, "member")) return 1;
    return 0;
}

fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

fn resolveWorkspaceId(ctx: *zfinal.Context) !?[]const u8 {
    // 1. X-Workspace-ID header
    if (ctx.getHeader("X-Workspace-ID")) |id| {
        if (id.len > 0) return try ctx.allocator.dupe(u8, id);
    }

    // 2. ?workspace_id=<uuid>
    if (try ctx.getPara("workspace_id")) |id| {
        if (id.len > 0) return try ctx.allocator.dupe(u8, id);
    }

    // 3. X-Workspace-Slug header
    if (ctx.getHeader("X-Workspace-Slug")) |slug| {
        if (slug.len > 0) {
            if (try resolveSlug(ctx, slug)) |id| return id;
        }
    }

    // 4. ?workspace_slug=<slug>
    if (try ctx.getPara("workspace_slug")) |slug| {
        if (slug.len > 0) {
            if (try resolveSlug(ctx, slug)) |id| return id;
        }
    }

    // 5. URL path param :id for /api/workspaces/:id/*
    if (ctx.getPathParam("id")) |id| {
        if (id.len > 0) return try ctx.allocator.dupe(u8, id);
    }

    return null;
}

fn resolveSlug(ctx: *zfinal.Context, slug: []const u8) !?[]const u8 {
    if (borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id FROM workspace WHERE slug = $1",
            &[_]SqlParam{.{ .text = slug }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        const id = rs.rows.items[0].getText(0) orelse return null;
        return try ctx.allocator.dupe(u8, id);
    }
    return null;
}

fn workspaceRoleCheck(ctx: *zfinal.Context, min_role: []const u8) !bool {
    const user_id = ctx.attributes.get("user_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return false;
    };

    const workspace_id = (try resolveWorkspaceId(ctx)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "workspace not found" });
        return false;
    };
    defer ctx.allocator.free(workspace_id);

    if (borrowDb()) |db| {
        defer deps.releaseBack(db);
        const sql =
            \\SELECT role FROM member WHERE workspace_id = $1 AND user_id = $2
        ;
        var rs = db.queryParams(sql, &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
        }) catch |err| {
            log.err("membership check failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return false;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace not found" });
            return false;
        }

        const role = rs.rows.items[0].getText(0) orelse "";
        if (roleRank(role) < roleRank(min_role)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return false;
        }

        try ctx.setAttr("workspace_id", workspace_id);
        try ctx.setAttr("workspace_role", role);
        return true;
    }

    // No-DB fallback: allow the request as owner for smoke tests / local dev.
    try ctx.setAttr("workspace_id", workspace_id);
    try ctx.setAttr("workspace_role", "owner");
    return true;
}

/// Requires at least the "member" role for the resolved workspace.
pub const RequireWorkspaceMember = RequireWorkspaceRole("member");

/// Require at least `min_role` ("member", "admin", or "owner") for the workspace.
pub fn RequireWorkspaceRole(comptime min_role: []const u8) zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "workspace-role-" ++ min_role,
        .before = struct {
            fn before(ctx: *zfinal.Context) !bool {
                return try workspaceRoleCheck(ctx, min_role);
            }
        }.before,
    };
}

/// Constant-time compare of two string slices. Returns false whenever
/// the lengths differ so the comparison itself never leaks the token
/// length. Used by `RequireServiceOrWorkspaceRole` to validate the
/// `X-Service-Token` header against `Config.service_token` without
/// short-circuiting on the first mismatching byte.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Pure decision helper extracted from `RequireServiceOrWorkspaceRole`
/// so the bypass logic can be unit-tested without standing up a full
/// `zfinal.Context` or a full `Config`. Returns true when the
/// `X-Service-Token` header value should bypass the workspace role
/// check for the given configured token. Pass an empty `configured`
/// to model the "bypass disabled" default.
fn serviceTokenBypasses(configured: []const u8, header_value: ?[]const u8) bool {
    if (configured.len == 0) return false;
    const hv = header_value orelse return false;
    if (hv.len == 0) return false;
    return constantTimeEql(hv, configured);
}

/// Service-account bypass layered on top of the workspace role check.
///
/// If the request carries an `X-Service-Token` header that matches
/// `Config.service_token` (constant-time), the request is allowed
/// through without a workspace context, and `service_actor="true"` is
/// stored on the context so downstream handlers / audit logs can
/// distinguish a service caller from a real workspace member. The
/// `workspace_id` attribute is *not* set in that case (the request is
/// not associated with a specific workspace).
///
/// When the header is absent, empty, mismatched, or the configured
/// token is empty (the default), the helper falls through to
/// `workspaceRoleCheck` exactly as `RequireWorkspaceRole` would.
pub fn RequireServiceOrWorkspaceRole(comptime min_role: []const u8) zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "service-or-workspace-role-" ++ min_role,
        .before = struct {
            fn before(ctx: *zfinal.Context) !bool {
                const configured = if (g_cfg) |c| c.service_token else "";
                if (serviceTokenBypasses(configured, ctx.getHeader("X-Service-Token"))) {
                    try ctx.setAttr("service_actor", "true");
                    return true;
                }
                return try workspaceRoleCheck(ctx, min_role);
            }
        }.before,
    };
}

test "constantTimeEql returns true for equal strings and false otherwise" {
    try std.testing.expect(constantTimeEql("", ""));
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(constantTimeEql("a-longer-secret", "a-longer-secret"));

    // Mismatched content.
    try std.testing.expect(!constantTimeEql("abc", "abd"));
    try std.testing.expect(!constantTimeEql("a-longer-secret", "a-longer-SECRET"));
    // Length mismatch — never equal regardless of content.
    try std.testing.expect(!constantTimeEql("abc", "abcd"));
    try std.testing.expect(!constantTimeEql("abcd", "abc"));
    // Empty vs non-empty.
    try std.testing.expect(!constantTimeEql("", "abc"));
    try std.testing.expect(!constantTimeEql("abc", ""));
}

test "serviceTokenBypasses honours configured-token + header rules" {
    // No config wired up: never bypass (empty configured token).
    try std.testing.expect(!serviceTokenBypasses("", "anything"));
    try std.testing.expect(!serviceTokenBypasses("", null));

    // Empty configured token: never bypass (the default).
    try std.testing.expect(!serviceTokenBypasses("", "any"));
    try std.testing.expect(!serviceTokenBypasses("", null));

    // Configured token + matching header: bypass.
    try std.testing.expect(serviceTokenBypasses("super-secret-token", "super-secret-token"));
    // Header absent / empty / wrong: no bypass.
    try std.testing.expect(!serviceTokenBypasses("super-secret-token", null));
    try std.testing.expect(!serviceTokenBypasses("super-secret-token", ""));
    try std.testing.expect(!serviceTokenBypasses("super-secret-token", "super-secret-tokeN"));
    try std.testing.expect(!serviceTokenBypasses("super-secret-token", "super-secret"));
    try std.testing.expect(!serviceTokenBypasses("super-secret-token", "xsuper-secret-token"));
}
