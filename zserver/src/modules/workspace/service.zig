//! Workspace module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory workspace /
//! member / invitation / GitHub / Lark tables) and exposes the
//! twenty-one HTTP-facing operations: `listWorkspaces`,
//! `createWorkspace`, `getWorkspace`, `updateWorkspace`,
//! `deleteWorkspace`, `listMembers`, `addMember`, `updateMemberRole`,
//! `removeMember`, `leaveWorkspace`, `listInvitations`,
//! `createInvitation`, `deleteInvitation`, `listGithubInstallations`,
//! `connectGithub`, `connectGithubInstallation`,
//! `deleteGithubInstallation`, `listLarkInstallations`, `connectLark`,
//! `deleteLarkInstallation`, `beginLarkInstall`, `getLarkInstallStatus`.
//!
//! The `handler.zig` is a thin delegate; data shapes and the
//! `WorkspaceResponse` projector live in `model.zig`.
//!
//! The DB access goes through `deps.acquire()` + `zfinal.DB` +
//! `zfinal.SqlParam` directly (Pattern 3 of
//! `HANDLER_MIGRATION_GUIDE.md`). The no-DB fallback mutates the
//! in-memory `WorkspaceEntry` / `MemberEntry` / `InvitationEntry`
//! records guarded by `model.mem_mutex` — this path is exercised by
//! the smoke test.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const util = @import("../../util.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.workspace_service);

/// Flat workspace entry for tree-building (shared type to avoid anonymous struct mismatch).
const WorkspaceFlatEntry = struct { id: []const u8, name: []const u8, slug: []const u8, parent_id: []const u8 };

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// listWorkspaces / createWorkspace
// ──────────────────────────────────────────────────────────────────────

pub fn listWorkspaces(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = model.getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var rs = try db_handle.queryParams(
            "SELECT w.id::text, w.name, w.slug, w.description, w.context, w.settings::text, w.repos::text, " ++
                "w.issue_prefix, w.avatar_url, w.created_at, w.updated_at " ++
                "FROM member m JOIN workspace w ON w.id = m.workspace_id " ++
                "WHERE m.user_id = $1 ORDER BY w.created_at ASC",
            &[_]SqlParam{.{ .text = u.id }},
        );
        defer rs.deinit();

        var list: std.ArrayList(model.WorkspaceResponse) = .empty;
        defer list.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            var settings_holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (settings_holder) |p| p.deinit();
            var repos_holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (repos_holder) |p| p.deinit();
            try list.append(allocator, try model.workspaceResponseFromRow(allocator, rs, i, &settings_holder, &repos_holder));
        }

        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.WorkspaceResponse) = .empty;
        defer list.deinit(allocator);

        var it = model.mem_workspaces.?.iterator();
        while (it.next()) |e| {
            if (model.memGetRole(e.key_ptr.*, u.id) != null) {
                try list.append(allocator, model.memWorkspaceResponse(e.value_ptr.*));
            }
        }
        try ctx.renderJson(list.items);
    }
}

pub fn createWorkspace(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = model.getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "not_configured" });
        return;
    };

    if (cfg.app.workspace_creation_disabled) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "workspace_creation_disabled" });
        return;
    }

    const parsed = try ctx.parseJsonBody(model.CreateWorkspaceRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    const slug_raw = std.mem.trim(u8, req.slug, &std.ascii.whitespace);
    const slug = try util.dupeLower(allocator, slug_raw);
    defer allocator.free(slug);

    if (name.len == 0 or slug.len == 0 or !model.isValidSlug(slug)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_name_or_slug" });
        return;
    }

    var prefix_buf: [3]u8 = undefined;
    const issue_prefix = blk: {
        if (req.issue_prefix) |p| {
            const trimmed = std.mem.trim(u8, p, &std.ascii.whitespace);
            if (trimmed.len > 0) break :blk trimmed;
        }
        break :blk model.defaultIssuePrefix(name, &prefix_buf);
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var wres = db_handle.queryParams(
            "INSERT INTO workspace (name, slug, description, context, issue_prefix) " ++
                "VALUES ($1, $2, $3, $4, $5) RETURNING id::text, name, slug, description, context, settings::text, repos::text, issue_prefix, avatar_url, created_at, updated_at",
            &[_]SqlParam{
                .{ .text = name },
                .{ .text = slug },
                .{ .text = req.description orelse "" },
                .{ .text = req.context orelse "" },
                .{ .text = issue_prefix },
            },
        ) catch |err| {
            log.err("create workspace failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "workspace_creation_failed" });
            return;
        };
        defer wres.deinit();

        if (wres.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "workspace_creation_failed" });
            return;
        }
        const workspace_id = wres.rows.items[0].getText(0) orelse "";

        var mres = db_handle.queryParams(
            "INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, 'owner') RETURNING id",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = u.id },
            },
        ) catch |err| {
            log.err("create member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "member_creation_failed" });
            return;
        };
        defer mres.deinit();

        var settings_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (settings_holder) |p| p.deinit();
        var repos_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (repos_holder) |p| p.deinit();
        const resp = try model.workspaceResponseFromRow(allocator, wres, 0, &settings_holder, &repos_holder);

        ctx.res_status = .created;
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const id = try model.memGenerateId(allocator, slug, u.id);
        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const now_str = try model.memFmtNumber(now);

        const entry = model.WorkspaceEntry{
            .id = id,
            .name = try model.memDup(name),
            .slug = try model.memDup(slug),
            .description = try model.memDup(req.description orelse ""),
            .context = try model.memDup(req.context orelse ""),
            .issue_prefix = try model.memDup(issue_prefix),
            .avatar_url = try model.memDup(""),
            .created_at = now_str,
            .updated_at = try model.memDup(now_str),
            .owner_id = try model.memDup(u.id),
            .parent_id = try model.memDup(""),
        };
        try model.mem_workspaces.?.put(entry.id, entry);

        var members: std.ArrayList(model.MemberEntry) = .empty;
        try members.append(model.memAlloc(), .{
            .user_id = try model.memDup(u.id),
            .role = try model.memDup("owner"),
            .name = try model.memDup(u.email),
            .email = try model.memDup(u.email),
        });
        try model.mem_members.?.put(entry.id, members);

        ctx.res_status = .created;
        try ctx.renderJson(model.memWorkspaceResponse(entry));
    }
}

// ──────────────────────────────────────────────────────────────────────
// getWorkspace / updateWorkspace / deleteWorkspace
// ──────────────────────────────────────────────────────────────────────

pub fn getWorkspace(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "member") == null) return;

        var rs = db_handle.queryParams(
            "SELECT id::text, name, slug, description, context, settings::text, repos::text, issue_prefix, avatar_url, created_at, updated_at " ++
                "FROM workspace WHERE id = $1",
            &[_]SqlParam{.{ .text = workspace_id }},
        ) catch |err| {
            log.err("get workspace failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        }

        var settings_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (settings_holder) |p| p.deinit();
        var repos_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (repos_holder) |p| p.deinit();
        const resp = try model.workspaceResponseFromRow(allocator, rs, 0, &settings_holder, &repos_holder);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const entry = model.mem_workspaces.?.get(workspace_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        };
        try ctx.renderJson(model.memWorkspaceResponse(entry));
    }
}

pub fn updateWorkspace(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateWorkspaceRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "admin") == null) return;

        const name = if (req.name) |n| std.mem.trim(u8, n, &std.ascii.whitespace) else null;
        if (name != null and name.?.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name_required" });
            return;
        }

        const settings_json = if (req.settings) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else null;
        defer if (settings_json) |s| allocator.free(s);
        const repos_json = if (req.repos) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else null;
        defer if (repos_json) |s| allocator.free(s);

        const params = [_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name orelse "" },
            .{ .text = req.description orelse "" },
            .{ .text = req.context orelse "" },
            .{ .text = settings_json orelse "" },
            .{ .text = repos_json orelse "" },
            .{ .text = req.issue_prefix orelse "" },
            .{ .text = req.avatar_url orelse "" },
        };
        var rs = db_handle.queryParams(
            "UPDATE workspace SET " ++
                "name = COALESCE(NULLIF($2, ''), name), " ++
                "description = COALESCE(NULLIF($3, ''), description), " ++
                "context = COALESCE(NULLIF($4, ''), context), " ++
                "settings = CASE WHEN $5 = '' THEN settings ELSE $5::jsonb END, " ++
                "repos = CASE WHEN $6 = '' THEN repos ELSE $6::jsonb END, " ++
                "issue_prefix = COALESCE(NULLIF($7, ''), issue_prefix), " ++
                "avatar_url = COALESCE(NULLIF($8, ''), avatar_url), " ++
                "updated_at = now() " ++
                "WHERE id = $1 " ++
                "RETURNING id::text, name, slug, description, context, settings::text, repos::text, issue_prefix, avatar_url, created_at, updated_at",
            &params,
        ) catch |err| {
            log.err("update workspace failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        }

        var settings_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (settings_holder) |p| p.deinit();
        var repos_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (repos_holder) |p| p.deinit();
        const resp = try model.workspaceResponseFromRow(allocator, rs, 0, &settings_holder, &repos_holder);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const entry = model.mem_workspaces.?.getPtr(workspace_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        };

        const name = if (req.name) |n| std.mem.trim(u8, n, &std.ascii.whitespace) else null;
        if (name != null and name.?.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name_required" });
            return;
        }

        const new_name = if (name) |n| try model.memDup(n) else entry.name;
        const new_description = if (req.description) |d| try model.memDup(d) else entry.description;
        const new_context = if (req.context) |c| try model.memDup(c) else entry.context;
        const new_issue_prefix = if (req.issue_prefix) |p| try model.memDup(p) else entry.issue_prefix;
        const new_avatar_url = if (req.avatar_url) |a| try model.memDup(a) else entry.avatar_url;
        entry.name = new_name;
        entry.description = new_description;
        entry.context = new_context;
        entry.issue_prefix = new_issue_prefix;
        entry.avatar_url = new_avatar_url;
        entry.updated_at = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
        try ctx.renderJson(model.memWorkspaceResponse(entry.*));
    }
}

pub fn deleteWorkspace(ctx: *zfinal.Context) !void {
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "owner") == null) return;

        try db_handle.execParams("DELETE FROM workspace WHERE id = $1", &[_]SqlParam{.{ .text = workspace_id }});
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "owner"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        _ = model.mem_workspaces.?.fetchRemove(workspace_id);
        _ = model.mem_members.?.fetchRemove(workspace_id);
        try response.okNoContent(ctx);
    }
}

// ──────────────────────────────────────────────────────────────────────
// listMembers / addMember
// ──────────────────────────────────────────────────────────────────────

pub fn listMembers(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "member") == null) return;

        var rs = try db_handle.queryParams(
            "SELECT m.id, m.workspace_id, m.user_id, m.role, m.created_at, " ++
                "u.name, u.email, u.avatar_url " ++
                "FROM member m JOIN \"user\" u ON u.id = m.user_id " ++
                "WHERE m.workspace_id = $1 ORDER BY m.created_at ASC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();

        var list: std.ArrayList(model.MemberResponse) = .empty;
        defer list.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.MemberResponse{
                .id = r.getText(0) orelse "",
                .workspace_id = r.getText(1) orelse "",
                .user_id = r.getText(2) orelse "",
                .role = r.getText(3) orelse "",
                .created_at = r.getText(4) orelse "",
                .name = r.getText(5) orelse "",
                .email = r.getText(6) orelse "",
                .avatar_url = r.getText(7),
            });
        }

        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.MemberResponse) = .empty;
        defer list.deinit(allocator);

        const member_list = model.mem_members.?.get(workspace_id) orelse {
            try ctx.renderJson(list.items);
            return;
        };
        for (member_list.items, 0..) |m, i| {
            const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ workspace_id, i });
            try list.append(allocator, model.MemberResponse{
                .id = id,
                .workspace_id = workspace_id,
                .user_id = m.user_id,
                .role = m.role,
                .created_at = "",
                .name = m.name,
                .email = m.email,
                .avatar_url = null,
            });
        }
        try ctx.renderJson(list.items);
    }
}

pub fn addMember(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;
    const inviter_id = model.getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateMemberRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const email_raw = std.mem.trim(u8, req.email, &std.ascii.whitespace);
    if (email_raw.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "email_required" });
        return;
    }
    const email = try util.dupeLower(allocator, email_raw);
    defer allocator.free(email);

    const role = model.normalizeMemberRole(req.role);
    if (role.len == 0 or std.mem.eql(u8, role, "owner")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_member_role" });
        return;
    }

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var user_res = db_handle.queryParams(
            "SELECT id, name, email, avatar_url FROM \"user\" WHERE email = $1",
            &[_]SqlParam{.{ .text = email }},
        ) catch |err| {
            log.err("addMember: lookup user failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer user_res.deinit();

        if (user_res.rows.items.len > 0) {
            const user_id = user_res.rows.items[0].getText(0) orelse "";
            const user_name = user_res.rows.items[0].getText(1) orelse email;
            const user_avatar = user_res.rows.items[0].getText(3);

            var check_res = db_handle.queryParams(
                "SELECT 1 FROM member WHERE workspace_id = $1 AND user_id = $2",
                &[_]SqlParam{
                    .{ .text = workspace_id },
                    .{ .text = user_id },
                },
            ) catch |err| {
                log.err("addMember: membership check failed: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
            defer check_res.deinit();
            if (check_res.rows.items.len > 0) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "user is already a member" });
                return;
            }

            var mres = db_handle.queryParams(
                "INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, $3) " ++
                    "RETURNING id, workspace_id, user_id, role, created_at",
                &[_]SqlParam{
                    .{ .text = workspace_id },
                    .{ .text = user_id },
                    .{ .text = role },
                },
            ) catch |err| {
                log.err("addMember: insert member failed: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "failed_to_add_member" });
                return;
            };
            defer mres.deinit();
            if (mres.rows.items.len == 0) {
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "failed_to_add_member" });
                return;
            }

            const mr = &mres.rows.items[0];
            ctx.res_status = .created;
            try ctx.renderJson(model.MemberResponse{
                .id = mr.getText(0) orelse "",
                .workspace_id = mr.getText(1) orelse "",
                .user_id = mr.getText(2) orelse "",
                .role = mr.getText(3) orelse "",
                .created_at = mr.getText(4) orelse "",
                .name = user_name,
                .email = email,
                .avatar_url = user_avatar,
            });
            return;
        }

        // No user: create an invitation instead.
        var pending_res = db_handle.queryParams(
            "SELECT id FROM workspace_invitation " ++
                "WHERE workspace_id = $1 AND invitee_email = $2 AND status = 'pending' AND expires_at > now()",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = email },
            },
        ) catch |err| {
            log.err("addMember: pending check failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer pending_res.deinit();
        if (pending_res.rows.items.len > 0) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "invitation already pending for this email" });
            return;
        }

        var inv_res = db_handle.queryParams(
            "INSERT INTO workspace_invitation (workspace_id, inviter_id, invitee_email, role, status, expires_at) " ++
                "VALUES ($1, $2, $3, $4, 'pending', now() + interval '7 days') " ++
                "RETURNING id, workspace_id, inviter_id, invitee_email, invitee_user_id, role, status, created_at, updated_at, expires_at",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = inviter_id },
                .{ .text = email },
                .{ .text = role },
            },
        ) catch |err| {
            log.err("addMember: insert invitation failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_invitation" });
            return;
        };
        defer inv_res.deinit();
        if (inv_res.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_invitation" });
            return;
        }

        const ir = &inv_res.rows.items[0];
        ctx.res_status = .created;
        try ctx.renderJson(model.InvitationResponse{
            .id = ir.getText(0) orelse "",
            .workspace_id = ir.getText(1) orelse "",
            .inviter_id = ir.getText(2) orelse "",
            .invitee_email = ir.getText(3) orelse "",
            .invitee_user_id = ir.getText(4),
            .role = ir.getText(5) orelse "",
            .status = ir.getText(6) orelse "",
            .created_at = ir.getText(7) orelse "",
            .updated_at = ir.getText(8) orelse "",
            .expires_at = ir.getText(9) orelse "",
            .inviter_name = "",
            .inviter_email = "",
        });
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        // In no-DB mode we always create a pending invitation: there is
        // no user-by-email lookup, so we cannot resolve an existing
        // account. The Go DB path's "user found → add member" branch
        // is intentionally out of scope for the in-memory fallback.
        {
            var it = model.mem_invitations.?.iterator();
            while (it.next()) |e| {
                const inv = e.value_ptr.*;
                if (std.mem.eql(u8, inv.workspace_id, workspace_id) and
                    std.mem.eql(u8, inv.invitee_email, email) and
                    std.mem.eql(u8, inv.status, "pending"))
                {
                    ctx.res_status = .conflict;
                    try ctx.renderJson(.{ .@"error" = "invitation already pending for this email" });
                    return;
                }
            }
        }
        const now_secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const now_str = try model.memFmtNumber(now_secs);
        const expires_str = try model.memFmtNumber(now_secs + 7 * 24 * 60 * 60);
        const id = try model.generateId(allocator, email);
        const entry = model.InvitationEntry{
            .id = try model.memDup(id),
            .workspace_id = try model.memDup(workspace_id),
            .inviter_id = try model.memDup(inviter_id),
            .invitee_email = try model.memDup(email),
            .role = try model.memDup(role),
            .status = try model.memDup("pending"),
            .created_at = try model.memDup(now_str),
            .updated_at = try model.memDup(now_str),
            .expires_at = try model.memDup(expires_str),
        };
        allocator.free(id);
        try model.mem_invitations.?.put(entry.id, entry);
        ctx.res_status = .created;
        try ctx.renderJson(model.InvitationResponse{
            .id = entry.id,
            .workspace_id = entry.workspace_id,
            .inviter_id = entry.inviter_id,
            .invitee_email = entry.invitee_email,
            .invitee_user_id = null,
            .role = entry.role,
            .status = entry.status,
            .created_at = entry.created_at,
            .updated_at = entry.updated_at,
            .expires_at = entry.expires_at,
            .inviter_name = "",
            .inviter_email = "",
        });
    }
}

// ──────────────────────────────────────────────────────────────────────
// updateMemberRole / removeMember / leaveWorkspace
// ──────────────────────────────────────────────────────────────────────

pub fn updateMemberRole(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    _ = allocator;
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    const requester_role = ctx.attributes.get("workspace_role") orelse "";
    if (model.roleRank(requester_role) < model.roleRank("admin")) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
        return;
    }

    const member_id = ctx.getPathParam("memberId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_member_id" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateMemberRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const new_role = model.normalizeMemberRole(req.role);
    if (new_role.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_member_role" });
        return;
    }

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var target_res = db_handle.queryParams(
            "SELECT id, user_id, role FROM member WHERE id = $1 AND workspace_id = $2",
            &[_]SqlParam{
                .{ .text = member_id },
                .{ .text = workspace_id },
            },
        ) catch |err| {
            log.err("updateMemberRole: load member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer target_res.deinit();
        if (target_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const target_role = target_res.rows.items[0].getText(2) orelse "";

        if ((std.mem.eql(u8, target_role, "owner") or std.mem.eql(u8, new_role, "owner")) and !std.mem.eql(u8, requester_role, "owner")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }

        if (std.mem.eql(u8, target_role, "owner") and !std.mem.eql(u8, new_role, "owner")) {
            var count_res = db_handle.queryParams(
                "SELECT COUNT(*) FROM member WHERE workspace_id = $1 AND role = 'owner'",
                &[_]SqlParam{.{ .text = workspace_id }},
            ) catch |err| {
                log.err("updateMemberRole: count owners failed: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
            defer count_res.deinit();
            const count = model.parseCount(count_res.rows.items[0].getText(0));
            if (count <= 1) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
                return;
            }
        }

        var upd_res = db_handle.queryParams(
            "UPDATE member SET role = $1 WHERE id = $2 RETURNING id, workspace_id, user_id, role, created_at",
            &[_]SqlParam{
                .{ .text = new_role },
                .{ .text = member_id },
            },
        ) catch |err| {
            log.err("updateMemberRole: update failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_update_member" });
            return;
        };
        defer upd_res.deinit();
        if (upd_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const user_id = upd_res.rows.items[0].getText(2) orelse "";

        var user_res = db_handle.queryParams(
            "SELECT name, email, avatar_url FROM \"user\" WHERE id = $1",
            &[_]SqlParam{.{ .text = user_id }},
        ) catch |err| {
            log.err("updateMemberRole: load user failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer user_res.deinit();
        const name = if (user_res.rows.items.len > 0) user_res.rows.items[0].getText(0) orelse "" else "";
        const email = if (user_res.rows.items.len > 0) user_res.rows.items[0].getText(1) orelse "" else "";
        const avatar = if (user_res.rows.items.len > 0) user_res.rows.items[0].getText(2) else null;

        const ur = &upd_res.rows.items[0];
        try ctx.renderJson(model.MemberResponse{
            .id = ur.getText(0) orelse "",
            .workspace_id = ur.getText(1) orelse "",
            .user_id = user_id,
            .role = ur.getText(3) orelse "",
            .created_at = ur.getText(4) orelse "",
            .name = name,
            .email = email,
            .avatar_url = avatar,
        });
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const list = model.mem_members.?.getPtr(workspace_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        };
        const member_idx = std.fmt.parseInt(usize, member_id, 10) catch {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        };
        if (member_idx >= list.items.len) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const target = &list.items[member_idx];
        if ((std.mem.eql(u8, target.role, "owner") or std.mem.eql(u8, new_role, "owner")) and !std.mem.eql(u8, requester_role, "owner")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        if (std.mem.eql(u8, target.role, "owner") and !std.mem.eql(u8, new_role, "owner") and model.memCountOwners(workspace_id) <= 1) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
            return;
        }
        target.role = try model.memDup(new_role);
        try ctx.renderJson(model.MemberResponse{
            .id = member_id,
            .workspace_id = workspace_id,
            .user_id = target.user_id,
            .role = target.role,
            .created_at = "",
            .name = target.name,
            .email = target.email,
            .avatar_url = null,
        });
    }
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    const requester_role = ctx.attributes.get("workspace_role") orelse "";
    const requester_id = model.getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const member_id = ctx.getPathParam("memberId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_member_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var target_res = db_handle.queryParams(
            "SELECT id, user_id, role FROM member WHERE id = $1 AND workspace_id = $2",
            &[_]SqlParam{
                .{ .text = member_id },
                .{ .text = workspace_id },
            },
        ) catch |err| {
            log.err("removeMember: load member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer target_res.deinit();
        if (target_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const target_user_id = target_res.rows.items[0].getText(1) orelse "";
        const target_role = target_res.rows.items[0].getText(2) orelse "";

        const is_self = std.mem.eql(u8, target_user_id, requester_id);
        if (!is_self and model.roleRank(requester_role) < model.roleRank("admin")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        if (std.mem.eql(u8, target_role, "owner") and !std.mem.eql(u8, requester_role, "owner")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        if (std.mem.eql(u8, target_role, "owner")) {
            var count_res = db_handle.queryParams(
                "SELECT COUNT(*) FROM member WHERE workspace_id = $1 AND role = 'owner'",
                &[_]SqlParam{.{ .text = workspace_id }},
            ) catch |err| {
                log.err("removeMember: count owners failed: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
            defer count_res.deinit();
            const count = model.parseCount(count_res.rows.items[0].getText(0));
            if (count <= 1) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
                return;
            }
        }

        db_handle.execParams("DELETE FROM member WHERE id = $1", &[_]SqlParam{.{ .text = member_id }}) catch |err| {
            log.err("removeMember: delete failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_remove_member" });
            return;
        };
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const list = model.mem_members.?.getPtr(workspace_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        };
        const member_idx = std.fmt.parseInt(usize, member_id, 10) catch {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        };
        if (member_idx >= list.items.len) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const target = list.items[member_idx];
        const is_self = std.mem.eql(u8, target.user_id, requester_id);
        if (!is_self and model.roleRank(requester_role) < model.roleRank("admin")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        if (std.mem.eql(u8, target.role, "owner") and !std.mem.eql(u8, requester_role, "owner")) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        if (std.mem.eql(u8, target.role, "owner") and model.memCountOwners(workspace_id) <= 1) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
            return;
        }
        _ = list.orderedRemove(member_idx);
        try response.okNoContent(ctx);
    }
}

pub fn leaveWorkspace(ctx: *zfinal.Context) !void {
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    const requester_id = model.getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var target_res = db_handle.queryParams(
            "SELECT id, role FROM member WHERE workspace_id = $1 AND user_id = $2",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = requester_id },
            },
        ) catch |err| {
            log.err("leaveWorkspace: load member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer target_res.deinit();
        if (target_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "member not found" });
            return;
        }
        const member_id = target_res.rows.items[0].getText(0) orelse "";
        const target_role = target_res.rows.items[0].getText(1) orelse "";

        if (std.mem.eql(u8, target_role, "owner")) {
            var count_res = db_handle.queryParams(
                "SELECT COUNT(*) FROM member WHERE workspace_id = $1 AND role = 'owner'",
                &[_]SqlParam{.{ .text = workspace_id }},
            ) catch |err| {
                log.err("leaveWorkspace: count owners failed: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
            defer count_res.deinit();
            const count = model.parseCount(count_res.rows.items[0].getText(0));
            if (count <= 1) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
                return;
            }
        }

        db_handle.execParams("DELETE FROM member WHERE id = $1", &[_]SqlParam{.{ .text = member_id }}) catch |err| {
            log.err("leaveWorkspace: delete failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_leave_workspace" });
            return;
        };
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const list = model.mem_members.?.getPtr(workspace_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "workspace_not_found" });
            return;
        };
        for (list.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.user_id, requester_id)) {
                if (std.mem.eql(u8, m.role, "owner") and model.memCountOwners(workspace_id) <= 1) {
                    ctx.res_status = .bad_request;
                    try ctx.renderJson(.{ .@"error" = "workspace must have at least one owner" });
                    return;
                }
                _ = list.orderedRemove(i);
                try response.okNoContent(ctx);
                return;
            }
        }
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "member not found" });
    }
}

// ──────────────────────────────────────────────────────────────────────
// listInvitations / createInvitation / deleteInvitation
// ──────────────────────────────────────────────────────────────────────

pub fn listInvitations(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "member") == null) return;

        var rs = try db_handle.queryParams(
            "SELECT wi.id, wi.workspace_id, wi.inviter_id, wi.invitee_email, wi.invitee_user_id, " ++
                "wi.role, wi.status, wi.created_at, wi.updated_at, wi.expires_at, " ++
                "u.name, u.email " ++
                "FROM workspace_invitation wi JOIN \"user\" u ON u.id = wi.inviter_id " ++
                "WHERE wi.workspace_id = $1 AND wi.status = 'pending' AND wi.expires_at > now() " ++
                "ORDER BY wi.created_at DESC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();

        var list: std.ArrayList(model.InvitationResponse) = .empty;
        defer list.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.InvitationResponse{
                .id = r.getText(0) orelse "",
                .workspace_id = r.getText(1) orelse "",
                .inviter_id = r.getText(2) orelse "",
                .invitee_email = r.getText(3) orelse "",
                .invitee_user_id = r.getText(4),
                .role = r.getText(5) orelse "",
                .status = r.getText(6) orelse "",
                .created_at = r.getText(7) orelse "",
                .updated_at = r.getText(8) orelse "",
                .expires_at = r.getText(9) orelse "",
                .inviter_name = r.getText(10) orelse "",
                .inviter_email = r.getText(11) orelse "",
            });
        }

        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.InvitationResponse) = .empty;
        defer list.deinit(allocator);
        if (model.mem_invitations) |*map| {
            var it = map.iterator();
            while (it.next()) |e| {
                const entry = e.value_ptr.*;
                if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
                try list.append(allocator, model.InvitationResponse{
                    .id = entry.id,
                    .workspace_id = entry.workspace_id,
                    .inviter_id = entry.inviter_id,
                    .invitee_email = entry.invitee_email,
                    .invitee_user_id = null,
                    .role = entry.role,
                    .status = entry.status,
                    .created_at = entry.created_at,
                    .updated_at = entry.updated_at,
                    .expires_at = entry.expires_at,
                    .inviter_name = "",
                    .inviter_email = "",
                });
            }
        }
        try ctx.renderJson(list.items);
    }
}

pub fn createInvitation(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;
    const inviter_id = model.getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateMemberRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const email_raw = std.mem.trim(u8, req.email, &std.ascii.whitespace);
    if (email_raw.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "email_required" });
        return;
    }
    const email = try util.dupeLower(allocator, email_raw);
    defer allocator.free(email);

    const role = model.normalizeMemberRole(req.role);
    if (role.len == 0 or std.mem.eql(u8, role, "owner")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_member_role" });
        return;
    }

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var pending_res = db_handle.queryParams(
            "SELECT id FROM workspace_invitation " ++
                "WHERE workspace_id = $1 AND invitee_email = $2 AND status = 'pending' AND expires_at > now()",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = email },
            },
        ) catch |err| {
            log.err("createInvitation: pending check failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer pending_res.deinit();
        if (pending_res.rows.items.len > 0) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "invitation already pending for this email" });
            return;
        }

        var inv_res = db_handle.queryParams(
            "INSERT INTO workspace_invitation (workspace_id, inviter_id, invitee_email, role, status, expires_at) " ++
                "VALUES ($1, $2, $3, $4, 'pending', now() + interval '7 days') " ++
                "RETURNING id, workspace_id, inviter_id, invitee_email, invitee_user_id, role, status, created_at, updated_at, expires_at",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = inviter_id },
                .{ .text = email },
                .{ .text = role },
            },
        ) catch |err| {
            log.err("createInvitation: insert failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_invitation" });
            return;
        };
        defer inv_res.deinit();
        if (inv_res.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_invitation" });
            return;
        }

        const ir = &inv_res.rows.items[0];
        ctx.res_status = .created;
        try ctx.renderJson(model.InvitationResponse{
            .id = ir.getText(0) orelse "",
            .workspace_id = ir.getText(1) orelse "",
            .inviter_id = ir.getText(2) orelse "",
            .invitee_email = ir.getText(3) orelse "",
            .invitee_user_id = ir.getText(4),
            .role = ir.getText(5) orelse "",
            .status = ir.getText(6) orelse "",
            .created_at = ir.getText(7) orelse "",
            .updated_at = ir.getText(8) orelse "",
            .expires_at = ir.getText(9) orelse "",
            .inviter_name = "",
            .inviter_email = "",
        });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;

        const now_ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const id = try model.memGenerateId(ctx.allocator, email, inviter_id);
        const entry = model.InvitationEntry{
            .id = try model.memDup(id),
            .workspace_id = try model.memDup(workspace_id),
            .inviter_id = try model.memDup(inviter_id),
            .invitee_email = try model.memDup(email),
            .role = try model.memDup(role),
            .status = try model.memDup("pending"),
            .created_at = try model.memFmtNumber(now_ts),
            .updated_at = try model.memFmtNumber(now_ts),
            .expires_at = try model.memFmtNumber(now_ts + 7 * 24 * 60 * 60),
        };
        try model.mem_invitations.?.put(entry.id, entry);
        allocator.free(id);

        ctx.res_status = .created;
        try ctx.renderJson(model.InvitationResponse{
            .id = entry.id,
            .workspace_id = entry.workspace_id,
            .inviter_id = entry.inviter_id,
            .invitee_email = entry.invitee_email,
            .invitee_user_id = null,
            .role = entry.role,
            .status = entry.status,
            .created_at = entry.created_at,
            .updated_at = entry.updated_at,
            .expires_at = entry.expires_at,
            .inviter_name = "",
            .inviter_email = "",
        });
    }
}

pub fn deleteInvitation(ctx: *zfinal.Context) !void {
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;

    const invitation_id = ctx.getPathParam("invitationId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_invitation_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var rs = db_handle.queryParams(
            "UPDATE workspace_invitation SET status = 'declined', updated_at = now() " ++
                "WHERE id = $1 AND workspace_id = $2 AND status = 'pending' RETURNING id",
            &[_]SqlParam{
                .{ .text = invitation_id },
                .{ .text = workspace_id },
            },
        ) catch |err| {
            log.err("deleteInvitation: update failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_delete_invitation" });
            return;
        };
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        }
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = model.mem_invitations.?.getPtr(invitation_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        }
        if (!std.mem.eql(u8, entry_ptr.status, "pending")) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "invitation is not pending" });
            return;
        }
        const now_str = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
        entry_ptr.status = try model.memDup("declined");
        entry_ptr.updated_at = try model.memDup(now_str);
        try response.okNoContent(ctx);
    }
}

// ──────────────────────────────────────────────────────────────────────
// GitHub integration
// ──────────────────────────────────────────────────────────────────────

pub fn listGithubInstallations(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        var rs = try db_handle.queryParams(
            "SELECT id, workspace_id, installation_id, account_login, " ++
                "COALESCE(account_avatar_url, '') AS account_url, " ++
                "account_type AS repository_selection, " ++
                "created_at, updated_at " ++
                "FROM github_installation WHERE workspace_id = $1::uuid ORDER BY created_at DESC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.GithubInstallationResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.GithubInstallationResponse{
                .id = r.getText(0) orelse "",
                .workspace_id = r.getText(1) orelse "",
                .installation_id = r.getText(2) orelse "",
                .account_login = r.getText(3) orelse "",
                .account_url = r.getText(4) orelse "",
                .repository_selection = r.getText(5) orelse "",
                .created_at = r.getText(6) orelse "",
                .updated_at = r.getText(7) orelse "",
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        if (!(try model.requireWorkspaceRoleAttr(ctx, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.GithubInstallationResponse) = .empty;
        defer list.deinit(allocator);
        var it = model.mem_github_installs.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            try list.append(allocator, model.githubResponseFromEntry(entry));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn connectGithub(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;

    const cfg = g_cfg.?;
    const app_slug = cfg.github_app_slug orelse "multica";
    const state = try model.generateId(allocator, workspace_id);
    defer allocator.free(state);
    const url = try std.fmt.allocPrint(allocator, "https://github.com/apps/{s}/installations/new?state={s}", .{ app_slug, state });
    defer allocator.free(url);

    try ctx.renderJson(.{ .url = url });
}

pub fn connectGithubInstallation(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;

    const parsed = try ctx.parseJsonBody(model.ConnectGithubInstallationRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const installation_id = std.mem.trim(u8, req.installation_id, &std.ascii.whitespace);
    if (installation_id.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "installation_id is required" });
        return;
    }

    // Note: the DB-backed INSERT path is not yet implemented (the
    // github_installation table migration is owned by the
    // platform/infra team). In both DB and no-DB modes we currently
    // persist to the in-memory map and return a synthesised response.
    // The branch on `deps.pool` is kept as a hook for the future
    // DB-only path without changing the response shape.
    if (deps.hasPool()) {
        // Future: write to github_installation here.
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var it = model.mem_github_installs.?.iterator();
    while (it.next()) |e| {
        const existing = e.value_ptr.*;
        if (std.mem.eql(u8, existing.workspace_id, workspace_id) and
            std.mem.eql(u8, existing.installation_id, installation_id))
        {
            e.value_ptr.account_login = try model.memDup(req.account_login orelse existing.account_login);
            e.value_ptr.account_url = try model.memDup(req.account_url orelse existing.account_url);
            e.value_ptr.repository_selection = try model.memDup(req.repository_selection orelse existing.repository_selection);
            e.value_ptr.updated_at = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
            try ctx.renderJson(model.githubResponseFromEntry(e.value_ptr.*));
            return;
        }
    }

    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const id = try model.generateId(allocator, installation_id);
    const entry = model.GithubInstallationEntry{
        .id = try model.memDup(id),
        .workspace_id = try model.memDup(workspace_id),
        .installation_id = try model.memDup(installation_id),
        .account_login = try model.memDup(req.account_login orelse ""),
        .account_url = try model.memDup(req.account_url orelse ""),
        .repository_selection = try model.memDup(req.repository_selection orelse "all"),
        .created_at = try model.memFmtNumber(now),
        .updated_at = try model.memFmtNumber(now),
    };
    try model.mem_github_installs.?.put(entry.id, entry);
    allocator.free(id);

    ctx.res_status = .created;
    try ctx.renderJson(model.githubResponseFromEntry(entry));
}

pub fn deleteGithubInstallation(ctx: *zfinal.Context) !void {
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;
    const installation_id = ctx.getPathParam("installationId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "installation_id is required" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        try db_handle.execParams(
            "DELETE FROM github_installation WHERE workspace_id = $1::uuid AND installation_id = $2",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = installation_id },
            },
        );
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var to_remove: ?[]const u8 = null;
        var it = model.mem_github_installs.?.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.workspace_id, workspace_id) and
                std.mem.eql(u8, e.value_ptr.installation_id, installation_id))
            {
                to_remove = e.key_ptr.*;
                break;
            }
        }
        if (to_remove) |key| {
            _ = model.mem_github_installs.?.fetchRemove(key);
        }
        try response.okNoContent(ctx);
    }
}

// ──────────────────────────────────────────────────────────────────────
// Lark integration
// ──────────────────────────────────────────────────────────────────────

pub fn listLarkInstallations(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        var rs = try db_handle.queryParams(
            "SELECT id, workspace_id, app_id, tenant_key, " ++
                "'' AS tenant_name, " ++
                "created_at, updated_at " ++
                "FROM lark_installation WHERE workspace_id = $1::uuid ORDER BY created_at DESC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.LarkInstallationResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.LarkInstallationResponse{
                .id = r.getText(0) orelse "",
                .workspace_id = r.getText(1) orelse "",
                .app_id = r.getText(2) orelse "",
                .tenant_key = r.getText(3) orelse "",
                .tenant_name = r.getText(4) orelse "",
                .created_at = r.getText(5) orelse "",
                .updated_at = r.getText(6) orelse "",
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        if (!(try model.requireWorkspaceRoleAttr(ctx, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.LarkInstallationResponse) = .empty;
        defer list.deinit(allocator);
        var it = model.mem_lark_installs.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            try list.append(allocator, model.larkResponseFromEntry(entry));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn deleteLarkInstallation(ctx: *zfinal.Context) !void {
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;
    const installation_id = ctx.getPathParam("installationId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "installation_id is required" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        try db_handle.execParams(
            "DELETE FROM lark_installation WHERE workspace_id = $1::uuid AND id = $2::uuid",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = installation_id },
            },
        );
        try response.okNoContent(ctx);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        _ = model.mem_lark_installs.?.fetchRemove(installation_id);
        try response.okNoContent(ctx);
    }
}

pub fn beginLarkInstall(ctx: *zfinal.Context) !void {
    // The Go server returns 503 when the Lark integration is not wired
    // (no MULTICA_LARK_SECRET_KEY / RegistrationService); the UI hides
    // the bind button in that case. zserver has no external Lark
    // registration service yet, so this endpoint always reports
    // "not configured" instead of fabricating an empty install URL.
    _ = ctx.getPathParam("id");
    ctx.res_status = .service_unavailable;
    try ctx.renderJson(.{ .@"error" = "lark install not configured" });
}

pub fn getLarkInstallStatus(ctx: *zfinal.Context) !void {
    _ = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        var rs = db_handle.queryParams(
            "SELECT status FROM lark_install_session WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = workspace_id },
            },
        ) catch |err| {
            log.err("getLarkInstallStatus: load failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "session not found" });
            return;
        }
        try ctx.renderJson(.{ .status = rs.rows.items[0].getText(0) orelse "pending" });
    } else {
        try model.memInit();
        if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_lark_sessions.?.get(session_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "session not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "session not found" });
            return;
        }
        try ctx.renderJson(.{ .status = entry.status });
    }
}

pub fn connectLark(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = model.getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    if (!(try model.requireWorkspaceRoleAttr(ctx, "admin"))) return;

    const parsed = try ctx.parseJsonBody(model.ConnectLarkRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const app_id = std.mem.trim(u8, req.app_id, &std.ascii.whitespace);
    const tenant_key = std.mem.trim(u8, req.tenant_key, &std.ascii.whitespace);
    if (app_id.len == 0 or tenant_key.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "app_id and tenant_key are required" });
        return;
    }

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        const params = [_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = app_id },
            .{ .text = tenant_key },
            .{ .text = req.tenant_name orelse "" },
        };
        var rs = try db_handle.queryParams(
            "INSERT INTO lark_installation (workspace_id, app_id, tenant_key, tenant_name) " ++
                "VALUES ($1::uuid, $2, $3, $4) " ++
                "ON CONFLICT (workspace_id, app_id, tenant_key) DO UPDATE SET " ++
                "tenant_name = EXCLUDED.tenant_name, updated_at = now() " ++
                "RETURNING id, workspace_id, app_id, tenant_key, tenant_name, created_at, updated_at",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to connect lark" });
            return;
        }
        const r = &rs.rows.items[0];
        ctx.res_status = .created;
        try ctx.renderJson(model.LarkInstallationResponse{
            .id = r.getText(0) orelse "",
            .workspace_id = r.getText(1) orelse "",
            .app_id = r.getText(2) orelse "",
            .tenant_key = r.getText(3) orelse "",
            .tenant_name = r.getText(4) orelse "",
            .created_at = r.getText(5) orelse "",
            .updated_at = r.getText(6) orelse "",
        });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var it = model.mem_lark_installs.?.iterator();
        while (it.next()) |e| {
            const existing = e.value_ptr.*;
            if (std.mem.eql(u8, existing.workspace_id, workspace_id) and
                std.mem.eql(u8, existing.app_id, app_id) and
                std.mem.eql(u8, existing.tenant_key, tenant_key))
            {
                e.value_ptr.tenant_name = try model.memDup(req.tenant_name orelse existing.tenant_name);
                e.value_ptr.updated_at = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
                try ctx.renderJson(model.larkResponseFromEntry(e.value_ptr.*));
                return;
            }
        }

        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const id = try model.generateId(allocator, tenant_key);
        const entry = model.LarkInstallationEntry{
            .id = try model.memDup(id),
            .workspace_id = try model.memDup(workspace_id),
            .app_id = try model.memDup(app_id),
            .tenant_key = try model.memDup(tenant_key),
            .tenant_name = try model.memDup(req.tenant_name orelse ""),
            .created_at = try model.memFmtNumber(now),
            .updated_at = try model.memFmtNumber(now),
        };
        try model.mem_lark_installs.?.put(entry.id, entry);
        allocator.free(id);

        ctx.res_status = .created;
        try ctx.renderJson(model.larkResponseFromEntry(entry));
    }
}

// ──────────────────────────────────────────────────────────────────────
// multi-tenancy V2: children, tree, limits
// ──────────────────────────────────────────────────────────────────────

pub fn createChildWorkspace(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = model.getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateChildWorkspaceRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const parent_id = std.mem.trim(u8, req.parent_id, &std.ascii.whitespace);
    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    const slug_raw = std.mem.trim(u8, req.slug, &std.ascii.whitespace);
    const slug = try util.dupeLower(allocator, slug_raw);
    defer allocator.free(slug);

    if (parent_id.len == 0 or name.len == 0 or slug.len == 0 or !model.isValidSlug(slug)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_parent_id_name_or_slug" });
        return;
    }

    var prefix_buf: [3]u8 = undefined;
    const issue_prefix = blk: {
        if (req.issue_prefix) |p| {
            const trimmed = std.mem.trim(u8, p, &std.ascii.whitespace);
            if (trimmed.len > 0) break :blk trimmed;
        }
        break :blk model.defaultIssuePrefix(name, &prefix_buf);
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        // Verify caller is admin/owner of parent.
        if (try model.requireAccess(ctx, db_handle, parent_id, "admin") == null) return;

        var wres = db_handle.queryParams(
            "INSERT INTO workspace (name, slug, description, context, issue_prefix, parent_id) " ++
                "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id::text, name, slug, description, context, settings::text, repos::text, issue_prefix, avatar_url, created_at, updated_at",
            &[_]SqlParam{
                .{ .text = name },
                .{ .text = slug },
                .{ .text = req.description orelse "" },
                .{ .text = req.context orelse "" },
                .{ .text = issue_prefix },
                .{ .text = parent_id },
            },
        ) catch |err| {
            log.err("create child workspace failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "workspace_creation_failed" });
            return;
        };
        defer wres.deinit();

        if (wres.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "workspace_creation_failed" });
            return;
        }
        const workspace_id = wres.rows.items[0].getText(0) orelse "";

        var mres = db_handle.queryParams(
            "INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, 'owner') RETURNING id",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = u.id },
            },
        ) catch |err| {
            log.err("create child member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "member_creation_failed" });
            return;
        };
        defer mres.deinit();

        var settings_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (settings_holder) |p| p.deinit();
        var repos_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (repos_holder) |p| p.deinit();
        const resp = try model.workspaceResponseFromRow(allocator, wres, 0, &settings_holder, &repos_holder);

        ctx.res_status = .created;
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        // Verify caller is admin/owner of parent.
        if (!(try model.memRequireAccess(ctx, parent_id, "admin"))) return;

        // Verify parent exists.
        if (!model.mem_workspaces.?.contains(parent_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "parent_workspace_not_found" });
            return;
        }

        const id = try model.memGenerateId(allocator, slug, u.id);
        const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
        const now_str = try model.memFmtNumber(now);

        const entry = model.WorkspaceEntry{
            .id = id,
            .name = try model.memDup(name),
            .slug = try model.memDup(slug),
            .description = try model.memDup(req.description orelse ""),
            .context = try model.memDup(req.context orelse ""),
            .issue_prefix = try model.memDup(issue_prefix),
            .avatar_url = try model.memDup(""),
            .created_at = now_str,
            .updated_at = try model.memDup(now_str),
            .owner_id = try model.memDup(u.id),
            .parent_id = try model.memDup(parent_id),
        };
        try model.mem_workspaces.?.put(entry.id, entry);

        var members: std.ArrayList(model.MemberEntry) = .empty;
        try members.append(model.memAlloc(), .{
            .user_id = try model.memDup(u.id),
            .role = try model.memDup("owner"),
            .name = try model.memDup(u.email),
            .email = try model.memDup(u.email),
        });
        try model.mem_members.?.put(entry.id, members);

        ctx.res_status = .created;
        try ctx.renderJson(model.memWorkspaceResponse(entry));
    }
}

pub fn getChildren(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "member") == null) return;

        var rs = db_handle.queryParams(
            "SELECT id::text, name, slug, description, context, settings::text, repos::text, issue_prefix, avatar_url, created_at, updated_at " ++
                "FROM workspace WHERE parent_id = $1 ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = workspace_id }},
        ) catch |err| {
            log.err("get children failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();

        var list: std.ArrayList(model.WorkspaceResponse) = .empty;
        defer list.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            var settings_holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (settings_holder) |p| p.deinit();
            var repos_holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (repos_holder) |p| p.deinit();
            try list.append(allocator, try model.workspaceResponseFromRow(allocator, rs, i, &settings_holder, &repos_holder));
        }

        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.WorkspaceResponse) = .empty;
        defer list.deinit(allocator);

        var it = model.mem_workspaces.?.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.parent_id, workspace_id)) {
                try list.append(allocator, model.memWorkspaceResponse(e.value_ptr.*));
            }
        }
        try ctx.renderJson(list.items);
    }
}

pub fn getWorkspaceTree(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = model.getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        var rs = db_handle.queryParams(
            "SELECT w.id, w.name, w.slug, w.description, w.context, w.settings, w.repos, " ++
                "w.issue_prefix, w.avatar_url, w.created_at, w.updated_at, COALESCE(w.parent_id::text, '') AS parent_id " ++
                "FROM member m JOIN workspace w ON w.id = m.workspace_id " ++
                "WHERE m.user_id = $1 ORDER BY w.created_at ASC",
            &[_]SqlParam{.{ .text = u.id }},
        ) catch |err| {
            log.err("workspace tree failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();

        var entries: std.ArrayList(WorkspaceFlatEntry) = .empty;
        defer entries.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            const eid = r.getText(0) orelse "";
            const ename = r.getText(1) orelse "";
            const eslug = r.getText(2) orelse "";
            const epid = r.getText(11) orelse "";
            try entries.append(allocator, .{
                .id = try allocator.dupe(u8, eid),
                .name = try allocator.dupe(u8, ename),
                .slug = try allocator.dupe(u8, eslug),
                .parent_id = try allocator.dupe(u8, epid),
            });
        }

        const tree = try buildTreeJson(allocator, entries.items);
        try ctx.renderJson(tree);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var entries: std.ArrayList(WorkspaceFlatEntry) = .empty;
        defer entries.deinit(allocator);

        var it = model.mem_workspaces.?.iterator();
        while (it.next()) |e| {
            if (model.memGetRole(e.key_ptr.*, u.id) != null) {
                try entries.append(allocator, .{
                    .id = try allocator.dupe(u8, e.value_ptr.id),
                    .name = try allocator.dupe(u8, e.value_ptr.name),
                    .slug = try allocator.dupe(u8, e.value_ptr.slug),
                    .parent_id = try allocator.dupe(u8, e.value_ptr.parent_id),
                });
            }
        }

        const tree = try buildTreeJson(allocator, entries.items);
        try ctx.renderJson(tree);
    }
}

fn buildTreeJson(
    allocator: std.mem.Allocator,
    entries: []WorkspaceFlatEntry,
) !std.json.Value {
    // Find root nodes (empty parent_id).
    var roots = std.json.Array.init(allocator);

    for (entries) |entry| {
        if (entry.parent_id.len == 0) {
            const node = try buildTreeNode(allocator, entries, entry.id, entry.name, entry.slug);
            try roots.append(node);
        }
    }

    return std.json.Value{ .array = roots };
}

fn buildTreeNode(
    allocator: std.mem.Allocator,
    entries: []WorkspaceFlatEntry,
    id: []const u8,
    name: []const u8,
    slug: []const u8,
) !std.json.Value {
    var children = std.json.Array.init(allocator);

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.parent_id, id)) {
            const child = try buildTreeNode(allocator, entries, entry.id, entry.name, entry.slug);
            try children.append(child);
        }
    }

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "id", std.json.Value{ .string = try allocator.dupe(u8, id) });
    try obj.put(allocator, "name", std.json.Value{ .string = try allocator.dupe(u8, name) });
    try obj.put(allocator, "slug", std.json.Value{ .string = try allocator.dupe(u8, slug) });
    try obj.put(allocator, "children", std.json.Value{ .array = children });

    return std.json.Value{ .object = obj };
}

pub fn setLimit(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.SetLimitRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "admin") == null) return;

        _ = try db_handle.queryParams(
            "INSERT INTO workspace_limits (workspace_id, max_members, max_storage, max_api_calls) " ++
                "VALUES ($1, $2, $3, $4) " ++
                "ON CONFLICT (workspace_id) DO UPDATE SET " ++
                "max_members = COALESCE($2, workspace_limits.max_members), " ++
                "max_storage = COALESCE($3, workspace_limits.max_storage), " ++
                "max_api_calls = COALESCE($4, workspace_limits.max_api_calls)",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = if (req.max_members) |v| try std.fmt.allocPrint(allocator, "{d}", .{v}) else "" },
                .{ .text = if (req.max_storage) |v| try std.fmt.allocPrint(allocator, "{d}", .{v}) else "" },
                .{ .text = if (req.max_api_calls) |v| try std.fmt.allocPrint(allocator, "{d}", .{v}) else "" },
            },
        );

        const limit = model.WorkspaceLimit{
            .max_members = req.max_members,
            .max_storage = req.max_storage,
            .max_api_calls = req.max_api_calls,
        };
        try ctx.renderJson(limit);
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "admin"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const limit = model.WorkspaceLimit{
            .max_members = req.max_members,
            .max_storage = req.max_storage,
            .max_api_calls = req.max_api_calls,
        };
        try model.mem_workspace_limits.?.put(workspace_id, limit);
        try ctx.renderJson(limit);
    }
}

pub fn getLimit(ctx: *zfinal.Context) !void {
    const workspace_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_workspace_id" });
        return;
    };

    if (model.borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);

        if (try model.requireAccess(ctx, db_handle, workspace_id, "member") == null) return;

        var rs = db_handle.queryParams(
            "SELECT max_members, max_storage, max_api_calls FROM workspace_limits WHERE workspace_id = $1",
            &[_]SqlParam{.{ .text = workspace_id }},
        ) catch |err| {
            log.err("get limit failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();

        if (rs.rows.items.len == 0) {
            try ctx.renderJson(model.WorkspaceLimit{
                .max_members = null,
                .max_storage = null,
                .max_api_calls = null,
            });
            return;
        }

        const r = &rs.rows.items[0];
        try ctx.renderJson(model.WorkspaceLimit{
            .max_members = model.parseCount(r.getText(0)),
            .max_storage = model.parseCount(r.getText(1)),
            .max_api_calls = model.parseCount(r.getText(2)),
        });
    } else {
        try model.memInit();
        if (!(try model.memRequireAccess(ctx, workspace_id, "member"))) return;
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const limit = model.mem_workspace_limits.?.get(workspace_id) orelse model.WorkspaceLimit{
            .max_members = null,
            .max_storage = null,
            .max_api_calls = null,
        };
        try ctx.renderJson(limit);
    }
}
