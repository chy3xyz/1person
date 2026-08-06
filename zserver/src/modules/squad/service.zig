//! Squad module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_squads` and
//! `mem_members`) and exposes the nine HTTP-facing operations:
//! `listSquads`, `getSquad`, `createSquad`, `updateSquad`, `deleteSquad`,
//! `listMembers`, `addMember`, `removeMember`, `memberStatus`. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const response = @import("../../common/response.zig");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.squad_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_squads: ?std.StringHashMap(model.SquadEntry) = null;
var mem_members: ?std.StringHashMap(std.ArrayList(model.SquadMemberEntry)) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_squads == null) {
        mem_squads = std.StringHashMap(model.SquadEntry).init(memAlloc());
        mem_members = std.StringHashMap(std.ArrayList(model.SquadMemberEntry)).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
        return common_mem.nowString();
    }

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getUserId(ctx);
    }

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

/// Require the caller to be the workspace owner/admin. Renders 403 and
/// returns `false` when the role is insufficient.
fn requireAdmin(ctx: *zfinal.Context) !bool {
    const role = getWorkspaceRole(ctx) orelse "";
    if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin")) return true;
    ctx.res_status = .forbidden;
    try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
    return false;
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

const CreateSquadRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    leader_id: []const u8,
    avatar_url: ?[]const u8 = null,
};

const UpdateSquadRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    leader_id: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
};

const AddMemberRequest = struct {
    member_type: []const u8,
    member_id: []const u8,
    role: []const u8,
};

const RemoveMemberRequest = struct {
    member_type: []const u8,
    member_id: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// list / get
// ──────────────────────────────────────────────────────────────────────

pub fn listSquads(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = try db.queryParams(
            "SELECT id, workspace_id, name, description, instructions, avatar_url, leader_id, creator_id, created_at, updated_at, archived_at, archived_by " ++
                "FROM squad WHERE workspace_id = $1::uuid ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();

        var list: std.ArrayList(model.SquadResponse) = .empty;
        defer {
            for (list.items) |item| allocator.free(item.member_preview);
            list.deinit(allocator);
        }
        for (0..rs.rows.items.len) |i| {
            const id = rs.rows.items[i].getText(0) orelse "";
            const members = try model.dbMembersForSquad(allocator, db, id);
            defer allocator.free(members);
            try list.append(allocator, try model.squadResponseFromRow(allocator, rs, i, members));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.SquadResponse) = .empty;
        defer {
            for (list.items) |item| allocator.free(item.member_preview);
            list.deinit(allocator);
        }
        var it = mem_squads.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            const members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
            try list.append(allocator, try model.squadResponseFromEntry(allocator, entry, members.items));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn getSquad(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = try db.queryParams(
            "SELECT id, workspace_id, name, description, instructions, avatar_url, leader_id, creator_id, created_at, updated_at, archived_at, archived_by " ++
                "FROM squad WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = workspace_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        const members = try model.dbMembersForSquad(allocator, db, squad_id);
        defer allocator.free(members);
        const resp = try model.squadResponseFromRow(allocator, rs, 0, members);
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.get(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        const members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
        const resp = try model.squadResponseFromEntry(allocator, entry, members.items);
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createSquad(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (!(try requireAdmin(ctx))) return;

    const parsed = try ctx.parseJsonBody(CreateSquadRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }
    if (req.leader_id.len == 0 or !model.looksLikeUuid(req.leader_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "leader_id is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var agent_check = try db.queryParams(
            "SELECT 1 FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = req.leader_id },
                .{ .text = workspace_id },
            },
        );
        defer agent_check.deinit();
        if (agent_check.rows.items.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "leader must be a valid agent in this workspace" });
            return;
        }

        const params = [_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = req.description orelse "" },
            .{ .text = req.leader_id },
            .{ .text = user_id },
            .{ .text = req.avatar_url orelse "" },
        };
        var rs = try db.queryParams(
            "INSERT INTO squad (workspace_id, name, description, leader_id, creator_id, avatar_url) " ++
                "VALUES ($1::uuid, $2, $3, $4::uuid, $5::uuid, NULLIF($6, '')) " ++
                "RETURNING id, workspace_id, name, description, instructions, avatar_url, leader_id, creator_id, created_at, updated_at, archived_at, archived_by",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create squad" });
            return;
        }

        const squad_id = rs.rows.items[0].getText(0) orelse "";
        try db.execParams(
            "INSERT INTO squad_member (squad_id, member_type, member_id, role) VALUES ($1::uuid, 'agent', $2::uuid, 'leader')",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = req.leader_id },
            },
        );

        const members = try model.dbMembersForSquad(allocator, db, squad_id);
        defer allocator.free(members);
        const resp = try model.squadResponseFromRow(allocator, rs, 0, members);
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = try model.generateId(allocator, name);
        const now = try nowString();
        const entry = model.SquadEntry{
            .id = try memDup(id),
            .workspace_id = try memDup(workspace_id),
            .name = try memDup(name),
            .description = try memDup(req.description orelse ""),
            .instructions = try memDup(""),
            .avatar_url = try memDup(req.avatar_url orelse ""),
            .leader_id = try memDup(req.leader_id),
            .creator_id = try memDup(user_id),
            .archived_at = try memDup(""),
            .archived_by = try memDup(""),
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
        };
        try mem_squads.?.put(entry.id, entry);

        var members: std.ArrayList(model.SquadMemberEntry) = .empty;
        try members.append(memAlloc(), model.SquadMemberEntry{
            .id = try model.generateId(memAlloc(), "squad-member"),
            .squad_id = try memDup(id),
            .member_type = try memDup("agent"),
            .member_id = try memDup(req.leader_id),
            .role = try memDup("leader"),
            .created_at = try memDup(now),
        });
        try mem_members.?.put(try memDup(id), members);

        const resp = try model.squadResponseFromEntry(allocator, entry, members.items);
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// update
// ──────────────────────────────────────────────────────────────────────

pub fn updateSquad(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (!(try requireAdmin(ctx))) return;

    const parsed = try ctx.parseJsonBody(UpdateSquadRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name) |n| {
        if (std.mem.trim(u8, n, &std.ascii.whitespace).len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name is required" });
            return;
        }
    }
    const leader_id = req.leader_id orelse "";
    if (leader_id.len > 0 and !model.looksLikeUuid(leader_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid leader_id" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        if (leader_id.len > 0) {
            var agent_check = try db.queryParams(
                "SELECT 1 FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
                &[_]SqlParam{
                    .{ .text = leader_id },
                    .{ .text = workspace_id },
                },
            );
            defer agent_check.deinit();
            if (agent_check.rows.items.len == 0) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "leader must be a valid agent in this workspace" });
                return;
            }
            try db.execParams(
                "INSERT INTO squad_member (squad_id, member_type, member_id, role) VALUES ($1::uuid, 'agent', $2::uuid, 'leader') " ++
                    "ON CONFLICT (squad_id, member_type, member_id) DO UPDATE SET role = 'leader'",
                &[_]SqlParam{
                    .{ .text = squad_id },
                    .{ .text = leader_id },
                },
            );
        }

        const params = [_]SqlParam{
            .{ .text = squad_id },
            .{ .text = workspace_id },
            .{ .text = req.name orelse "" },
            .{ .text = req.description orelse "" },
            .{ .text = req.instructions orelse "" },
            .{ .text = req.avatar_url orelse "" },
            .{ .text = leader_id },
        };
        var rs = try db.queryParams(
            "UPDATE squad SET " ++
                "name = COALESCE(NULLIF($3, ''), name), " ++
                "description = COALESCE(NULLIF($4, ''), description), " ++
                "instructions = COALESCE(NULLIF($5, ''), instructions), " ++
                "avatar_url = COALESCE(NULLIF($6, ''), avatar_url), " ++
                "leader_id = COALESCE(NULLIF($7, '')::uuid, leader_id), " ++
                "updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "RETURNING id, workspace_id, name, description, instructions, avatar_url, leader_id, creator_id, created_at, updated_at, archived_at, archived_by",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        const members = try model.dbMembersForSquad(allocator, db, squad_id);
        defer allocator.free(members);
        const resp = try model.squadResponseFromRow(allocator, rs, 0, members);
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.getPtr(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        if (req.name) |n| entry.name = try memDup(std.mem.trim(u8, n, &std.ascii.whitespace));
        if (req.description) |d| entry.description = try memDup(d);
        if (req.instructions) |i| entry.instructions = try memDup(i);
        if (req.avatar_url) |u| entry.avatar_url = try memDup(u);
        if (leader_id.len > 0) {
            entry.leader_id = try memDup(leader_id);
            var members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
            var found = false;
            for (members.items) |*m| {
                if (std.mem.eql(u8, m.member_id, leader_id) and std.mem.eql(u8, m.member_type, "agent")) {
                    m.role = try memDup("leader");
                    found = true;
                    break;
                }
            }
            if (!found) {
                try members.append(memAlloc(), model.SquadMemberEntry{
                    .id = try model.generateId(memAlloc(), "squad-member"),
                    .squad_id = try memDup(squad_id),
                    .member_type = try memDup("agent"),
                    .member_id = try memDup(leader_id),
                    .role = try memDup("leader"),
                    .created_at = try nowString(),
                });
            }
            try mem_members.?.put(try memDup(squad_id), members);
        }
        entry.updated_at = try nowString();
        const members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
        const resp = try model.squadResponseFromEntry(allocator, entry.*, members.items);
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// delete
// ──────────────────────────────────────────────────────────────────────

pub fn deleteSquad(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    if (!(try requireAdmin(ctx))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var rs = try db.queryParams(
            "UPDATE squad SET archived_at = now(), archived_by = $3::uuid, updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL " ++
                "RETURNING id",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        try response.okNoContent(ctx);
    return;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.getPtr(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        if (entry.archived_at.len > 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "squad is already archived" });
            return;
        }
        entry.archived_at = try nowString();
        entry.archived_by = try memDup(user_id);
        entry.updated_at = try nowString();
        try response.okNoContent(ctx);
    return;
    }
}

// ──────────────────────────────────────────────────────────────────────
// members
// ──────────────────────────────────────────────────────────────────────

pub fn listMembers(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var squad_check = try db.queryParams(
            "SELECT 1 FROM squad WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = workspace_id },
            },
        );
        defer squad_check.deinit();
        if (squad_check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }

        var rs = try db.queryParams(
            "SELECT id, squad_id, member_type, member_id, role, created_at FROM squad_member WHERE squad_id = $1::uuid ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = squad_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.SquadMemberResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, model.squadMemberResponseFromRow(rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.get(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        const members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
        var list: std.ArrayList(model.SquadMemberResponse) = .empty;
        defer list.deinit(allocator);
        for (members.items) |m| {
            try list.append(allocator, model.squadMemberResponseFromEntry(m));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn addMember(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (!(try requireAdmin(ctx))) return;

    const parsed = try ctx.parseJsonBody(AddMemberRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.isValidMemberType(req.member_type)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "member_type must be 'agent' or 'member'" });
        return;
    }
    if (req.member_id.len == 0 or !model.looksLikeUuid(req.member_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "member_id is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var squad_check = try db.queryParams(
            "SELECT 1 FROM squad WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = workspace_id },
            },
        );
        defer squad_check.deinit();
        if (squad_check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }

        var entity_check = if (std.mem.eql(u8, req.member_type, "agent"))
            try db.queryParams(
                "SELECT 1 FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
                &[_]SqlParam{
                    .{ .text = req.member_id },
                    .{ .text = workspace_id },
                },
            )
        else
            try db.queryParams(
                "SELECT 1 FROM member WHERE user_id = $1::uuid AND workspace_id = $2::uuid",
                &[_]SqlParam{
                    .{ .text = req.member_id },
                    .{ .text = workspace_id },
                },
            );
        defer entity_check.deinit();
        if (entity_check.rows.items.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = if (std.mem.eql(u8, req.member_type, "agent")) "agent not found in this workspace" else "member not found in this workspace" });
            return;
        }

        var rs = try db.queryParams(
            "INSERT INTO squad_member (squad_id, member_type, member_id, role) VALUES ($1::uuid, $2, $3::uuid, $4) " ++
                "ON CONFLICT (squad_id, member_type, member_id) DO UPDATE SET role = EXCLUDED.role " ++
                "RETURNING id, squad_id, member_type, member_id, role, created_at",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = req.member_type },
                .{ .text = req.member_id },
                .{ .text = req.role },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to add squad member" });
            return;
        }
        ctx.res_status = .created;
        try ctx.renderJson(model.squadMemberResponseFromRow(rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.get(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }

        var members = mem_members.?.get(entry.id) orelse std.ArrayList(model.SquadMemberEntry).empty;
        for (members.items) |m| {
            if (std.mem.eql(u8, m.member_type, req.member_type) and std.mem.eql(u8, m.member_id, req.member_id)) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "member already in squad" });
                return;
            }
        }

        const now = try nowString();
        const member = model.SquadMemberEntry{
            .id = try model.generateId(memAlloc(), "squad-member"),
            .squad_id = try memDup(squad_id),
            .member_type = try memDup(req.member_type),
            .member_id = try memDup(req.member_id),
            .role = try memDup(req.role),
            .created_at = try memDup(now),
        };
        try members.append(memAlloc(), member);
        try mem_members.?.put(try memDup(squad_id), members);
        ctx.res_status = .created;
        try ctx.renderJson(model.squadMemberResponseFromEntry(member));
    }
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (!(try requireAdmin(ctx))) return;

    const parsed = try ctx.parseJsonBody(RemoveMemberRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.isValidMemberType(req.member_type)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "member_type must be 'agent' or 'member'" });
        return;
    }
    if (req.member_id.len == 0 or !model.looksLikeUuid(req.member_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "member_id is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var squad_res = try db.queryParams(
            "SELECT leader_id FROM squad WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = workspace_id },
            },
        );
        defer squad_res.deinit();
        if (squad_res.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        const leader_id = squad_res.rows.items[0].getText(0) orelse "";
        if (std.mem.eql(u8, req.member_type, "agent") and std.mem.eql(u8, req.member_id, leader_id)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "cannot remove the squad leader; change leader first" });
            return;
        }

        var rs = try db.queryParams(
            "DELETE FROM squad_member WHERE squad_id = $1::uuid AND member_type = $2 AND member_id = $3::uuid RETURNING id",
            &[_]SqlParam{
                .{ .text = squad_id },
                .{ .text = req.member_type },
                .{ .text = req.member_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad member not found" });
            return;
        }
        try response.okNoContent(ctx);
    return;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_squads.?.get(squad_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad not found" });
            return;
        }
        if (std.mem.eql(u8, req.member_type, "agent") and std.mem.eql(u8, req.member_id, entry.leader_id)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "cannot remove the squad leader; change leader first" });
            return;
        }

        if (mem_members.?.getPtr(squad_id)) |members| {
            var i: usize = 0;
            var found = false;
            while (i < members.items.len) : (i += 1) {
                if (std.mem.eql(u8, members.items[i].member_type, req.member_type) and std.mem.eql(u8, members.items[i].member_id, req.member_id)) {
                    _ = members.orderedRemove(i);
                    found = true;
                    break;
                }
            }
            if (!found) {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "squad member not found" });
                return;
            }
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "squad member not found" });
            return;
        }
        try response.okNoContent(ctx);
    return;
    }
}

pub fn memberStatus(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const squad_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "squad_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT member_type, member_id FROM squad_member WHERE squad_id = $1::uuid ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = squad_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(struct { member_type: []const u8, member_id: []const u8, status: []const u8 }) = .empty;
        defer list.deinit(ctx.allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(ctx.allocator, .{
                .member_type = r.getText(0) orelse "",
                .member_id = r.getText(1) orelse "",
                .status = "offline",
            });
        }
        try ctx.renderJson(.{ .members = list.items, .workspace_id = workspace_id });
    } else {
        try ctx.renderJson(.{ .members = &[_]struct { member_type: []const u8, member_id: []const u8, status: []const u8 }{}, .workspace_id = workspace_id });
    }
}