//! Invitation module — business logic.
//!
//! Owns the per-process state (`mem_invitations`) and exposes four
//! HTTP-facing operations on `/api/invitations`: `listMyInvitations`,
//! `getMyInvitation`, `acceptInvitation`, `declineInvitation`. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.
//!
//! The `acceptInvitation` flow has the only cross-module side-effect:
//! on success it inserts a row into the `member` table and stamps the
//! `user.onboarded_at` column. The `workspace` module's helpers
//! (`InvitationResponse`, `memGetWorkspaceName`, `memAddMember`) are
//! imported from `../workspace/service.zig` (the migrated
//! `zfinal/ruoyi-gen`-style layout).

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const util = @import("../../util.zig");
const workspace = @import("../workspace/model.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");

const log = std.log.scoped(.invitation_service);

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_invitations: ?std.StringHashMap(model.InvitationEntry) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_invitations == null) {
        mem_invitations = std.StringHashMap(model.InvitationEntry).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn memFmtNumber(n: i64) ![]const u8 {
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{n});
}

fn getCurrentUser(ctx: *zfinal.Context) ?struct { id: []const u8, email: []const u8 } {
    const id = ctx.attributes.get("user_id") orelse return null;
    const email = ctx.attributes.get("email") orelse return null;
    return .{ .id = id, .email = email };
}

fn invitationEntryToResponse(entry: model.InvitationEntry, workspace_name: []const u8, inviter_name: []const u8, inviter_email: []const u8) workspace.InvitationResponse {
    return workspace.InvitationResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .workspace_name = workspace_name,
        .inviter_id = entry.inviter_id,
        .invitee_email = entry.invitee_email,
        .invitee_user_id = entry.invitee_user_id,
        .role = entry.role,
        .status = entry.status,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .expires_at = entry.expires_at,
        .inviter_name = inviter_name,
        .inviter_email = inviter_email,
    };
}

fn normalizeEmail(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return try util.dupeLower(allocator, std.mem.trim(u8, raw, &std.ascii.whitespace));
}

fn invitationBelongsToUser(inv: workspace.InvitationResponse, user_id: []const u8, email: []const u8) bool {
    if (std.mem.eql(u8, inv.invitee_email, email)) return true;
    if (inv.invitee_user_id) |uid| {
        if (std.mem.eql(u8, uid, user_id)) return true;
    }
    return false;
}

pub fn listMyInvitations(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = try db.queryParams(
            "SELECT wi.id, wi.workspace_id, wi.inviter_id, wi.invitee_email, wi.invitee_user_id, " ++
                "wi.role, wi.status, wi.created_at, wi.updated_at, wi.expires_at, " ++
                "u.name, u.email, w.name " ++
                "FROM workspace_invitation wi " ++
                "JOIN \"user\" u ON u.id = wi.inviter_id " ++
                "JOIN workspace w ON w.id = wi.workspace_id " ++
                "WHERE (wi.invitee_user_id = $1 OR wi.invitee_email = $2) " ++
                "AND wi.status = 'pending' AND wi.expires_at > now() " ++
                "ORDER BY wi.created_at DESC",
            &[_]SqlParam{
                .{ .text = u.id },
                .{ .text = u.email },
            },
        );
        defer rs.deinit();

        var list: std.ArrayList(workspace.InvitationResponse) = .empty;
        defer list.deinit(allocator);

        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, workspace.InvitationResponse{
                .id = r.getText(0) orelse "",
                .workspace_id = r.getText(1) orelse "",
                .workspace_name = r.getText(12) orelse "",
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
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(workspace.InvitationResponse) = .empty;
        defer list.deinit(allocator);

        var it = mem_invitations.?.iterator();
        while (it.next()) |e| {
            const inv = e.value_ptr.*;
            if (!std.mem.eql(u8, inv.status, "pending")) continue;
            if (std.mem.eql(u8, inv.invitee_email, u.email)) {
                try list.append(allocator, invitationEntryToResponse(inv, workspace.memGetWorkspaceName(inv.workspace_id) orelse "", "", ""));
            }
        }
        try ctx.renderJson(list.items);
    }
}

pub fn getMyInvitation(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const invitation_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_invitation_id" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = db.queryParams(
            "SELECT wi.id, wi.workspace_id, wi.inviter_id, wi.invitee_email, wi.invitee_user_id, " ++
                "wi.role, wi.status, wi.created_at, wi.updated_at, wi.expires_at, " ++
                "u.name, u.email, w.name " ++
                "FROM workspace_invitation wi " ++
                "JOIN \"user\" u ON u.id = wi.inviter_id " ++
                "JOIN workspace w ON w.id = wi.workspace_id " ++
                "WHERE wi.id = $1",
            &[_]SqlParam{.{ .text = invitation_id }},
        ) catch |err| {
            log.err("getMyInvitation: load failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        }
        const r0 = &rs.rows.items[0];
        const resp = workspace.InvitationResponse{
            .id = r0.getText(0) orelse "",
            .workspace_id = r0.getText(1) orelse "",
            .workspace_name = r0.getText(12) orelse "",
            .inviter_id = r0.getText(2) orelse "",
            .invitee_email = r0.getText(3) orelse "",
            .invitee_user_id = r0.getText(4),
            .role = r0.getText(5) orelse "",
            .status = r0.getText(6) orelse "",
            .created_at = r0.getText(7) orelse "",
            .updated_at = r0.getText(8) orelse "",
            .expires_at = r0.getText(9) orelse "",
            .inviter_name = r0.getText(10) orelse "",
            .inviter_email = r0.getText(11) orelse "",
        };
        if (!invitationBelongsToUser(resp, u.id, u.email)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const inv = mem_invitations.?.get(invitation_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        };
        if (!std.mem.eql(u8, inv.invitee_email, u.email)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        try ctx.renderJson(invitationEntryToResponse(inv, workspace.memGetWorkspaceName(inv.workspace_id) orelse "", "", ""));
    }
}

pub fn acceptInvitation(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const invitation_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_invitation_id" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var inv_res = db.queryParams(
            "SELECT id, workspace_id, inviter_id, invitee_email, invitee_user_id, role, status " ++
                "FROM workspace_invitation WHERE id = $1",
            &[_]SqlParam{.{ .text = invitation_id }},
        ) catch |err| {
            log.err("acceptInvitation: load failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer inv_res.deinit();
        if (inv_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        }
        const inv0 = &inv_res.rows.items[0];
        const invitee_email = inv0.getText(3) orelse "";
        const invitee_user_id = inv0.getText(4);
        const role = inv0.getText(5) orelse "member";
        const status = inv0.getText(6) orelse "";

        if (!std.mem.eql(u8, invitee_email, u.email) and (invitee_user_id == null or !std.mem.eql(u8, invitee_user_id.?, u.id))) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        if (!std.mem.eql(u8, status, "pending")) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invitation is not pending" });
            return;
        }

        const workspace_id = inv0.getText(1) orelse "";

        try db.exec("BEGIN");
        var committed = false;
        defer if (!committed) db.exec("ROLLBACK") catch {};

        var accept_res = db.queryParams(
            "UPDATE workspace_invitation SET status = 'accepted', updated_at = now() WHERE id = $1 " ++
                "RETURNING id, workspace_id, role",
            &[_]SqlParam{.{ .text = invitation_id }},
        ) catch |err| {
            log.err("acceptInvitation: accept failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_accept_invitation" });
            return;
        };
        defer accept_res.deinit();
        if (accept_res.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_accept_invitation" });
            return;
        }

        var mres = db.queryParams(
            "INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, $3) " ++
                "RETURNING id, workspace_id, user_id, role, created_at",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = u.id },
                .{ .text = role },
            },
        ) catch |err| {
            log.err("acceptInvitation: create member failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_membership" });
            return;
        };
        defer mres.deinit();
        if (mres.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_create_membership" });
            return;
        }

        var user_res = db.queryParams(
            "UPDATE \"user\" SET onboarded_at = COALESCE(onboarded_at, now()) WHERE id = $1 " ++
                "RETURNING id, name, email, avatar_url",
            &[_]SqlParam{.{ .text = u.id }},
        ) catch |err| {
            log.err("acceptInvitation: mark onboarded failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_mark_user_onboarded" });
            return;
        };
        defer user_res.deinit();
        const name = if (user_res.rows.items.len > 0) user_res.rows.items[0].getText(1) orelse u.email else u.email;
        const avatar = if (user_res.rows.items.len > 0) user_res.rows.items[0].getText(3) else null;

        try db.exec("COMMIT");
        committed = true;

        const m0 = &mres.rows.items[0];
        try ctx.renderJson(workspace.MemberResponse{
            .id = m0.getText(0) orelse "",
            .workspace_id = m0.getText(1) orelse "",
            .user_id = m0.getText(2) orelse "",
            .role = m0.getText(3) orelse "",
            .created_at = m0.getText(4) orelse "",
            .name = name,
            .email = u.email,
            .avatar_url = avatar,
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var inv = mem_invitations.?.getPtr(invitation_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        };
        if (!std.mem.eql(u8, inv.invitee_email, u.email)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        if (!std.mem.eql(u8, inv.status, "pending")) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invitation is not pending" });
            return;
        }
        inv.status = try memDup("accepted");
        inv.updated_at = try memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
        try workspace.memAddMember(inv.workspace_id, u.id, inv.role, u.email, u.email);
        try ctx.renderJson(workspace.MemberResponse{
            .id = invitation_id,
            .workspace_id = inv.workspace_id,
            .user_id = u.id,
            .role = inv.role,
            .created_at = inv.created_at,
            .name = u.email,
            .email = u.email,
            .avatar_url = null,
        });
    }
}

pub fn declineInvitation(ctx: *zfinal.Context) !void {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const invitation_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_invitation_id" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var inv_res = db.queryParams(
            "SELECT invitee_email, invitee_user_id, status FROM workspace_invitation WHERE id = $1",
            &[_]SqlParam{.{ .text = invitation_id }},
        ) catch |err| {
            log.err("declineInvitation: load failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "database_error" });
            return;
        };
        defer inv_res.deinit();
        if (inv_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        }
        const inv0 = &inv_res.rows.items[0];
        const invitee_email = inv0.getText(0) orelse "";
        const invitee_user_id = inv0.getText(1);
        const status = inv0.getText(2) orelse "";

        if (!std.mem.eql(u8, invitee_email, u.email) and (invitee_user_id == null or !std.mem.eql(u8, invitee_user_id.?, u.id))) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        if (!std.mem.eql(u8, status, "pending")) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invitation is not pending" });
            return;
        }

        db.execParams(
            "UPDATE workspace_invitation SET status = 'declined', updated_at = now() WHERE id = $1",
            &[_]SqlParam{.{ .text = invitation_id }},
        ) catch |err| {
            log.err("declineInvitation: update failed: {}", .{err});
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed_to_decline_invitation" });
            return;
        };
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        var inv = mem_invitations.?.getPtr(invitation_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invitation not found" });
            return;
        };
        if (!std.mem.eql(u8, inv.invitee_email, u.email)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "invitation does not belong to you" });
            return;
        }
        if (!std.mem.eql(u8, inv.status, "pending")) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invitation is not pending" });
            return;
        }
        inv.status = try memDup("declined");
        inv.updated_at = try memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
        ctx.res_status = .no_content;
    }
}
