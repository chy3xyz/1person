//! Role module — business logic.
//!
//! Owns the per-process state (g_cfg, in-memory stores) and exposes
//! the HTTP-facing operations: CRUD for role definitions, member
//! role assignment, and hierarchical queries (downline tree, upline
//! chain). The handler.zig is a thin delegate; SQL and data shapes
//! live in model.zig.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.role_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_role_configs: ?std.StringHashMap(model.RoleConfigEntry) = null;
var mem_member_roles: ?std.StringHashMap(model.MemberRoleEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_role_configs == null) {
        mem_role_configs = std.StringHashMap(model.RoleConfigEntry).init(memAlloc());
    }
    if (mem_member_roles == null) {
        mem_member_roles = std.StringHashMap(model.MemberRoleEntry).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

// Key used in mem_member_roles: "user_id::workspace_id"
fn memberKey(user_id: []const u8, workspace_id: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "{s}::{s}", .{ user_id, workspace_id });
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

const CreateRoleConfigRequest = struct {
    name: []const u8,
    permissions: []const u8 = "",
    upgrade_conditions: []const u8 = "",
    level: i64 = 0,
};

const UpdateRoleConfigRequest = struct {
    name: ?[]const u8 = null,
    permissions: ?[]const u8 = null,
    upgrade_conditions: ?[]const u8 = null,
    level: ?i64 = null,
};

const AssignRoleRequest = struct {
    user_id: []const u8,
    role: []const u8,
    level: i64 = 0,
    parent_id: ?[]const u8 = null,
};

const UpdateMemberRoleRequest = struct {
    role: ?[]const u8 = null,
    level: ?i64 = null,
    parent_id: ?[]const u8 = null,
};

// ──────────────────────────────────────────────────────────────────────
// RoleConfig CRUD
// ──────────────────────────────────────────────────────────────────────

pub fn listRoleConfigs(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbListRoleConfigs(allocator, workspace_id)) |items| {
            defer allocator.free(items);
            try ctx.renderJson(.{ .defs = items, .total = items.len });
            return;
        } else |_| {
            // DB query failed — fall through to in-memory
        }
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.RoleConfigResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_role_configs.?.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.*.workspace_id, workspace_id)) continue;
        try list.append(allocator, model.roleConfigResponseFromEntry(e.value_ptr.*));
    }
    try ctx.renderJson(.{ .defs = list.items, .total = list.items.len });
}

pub fn getRoleConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const role_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "role_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbGetRoleConfig(workspace_id, role_id)) |resp| {
            try ctx.renderJson(resp);
            return;
        }
        // DB failed or not found — fall through to in-memory
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_role_configs.?.get(role_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "role config not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "role config not found" });
        return;
    }
    try ctx.renderJson(model.roleConfigResponseFromEntry(entry));
}

pub fn createRoleConfig(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(CreateRoleConfigRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = model.validateRoleName(req.name) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required and must be 64 characters or fewer" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbCreateRoleConfig(workspace_id, name, req.permissions, req.upgrade_conditions, req.level)) |resp| {
            ctx.res_status = .created;
            try ctx.renderJson(resp);
            return;
        }
        // DB failed — fall through to in-memory
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // check for duplicate name in workspace
    var it = mem_role_configs.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.workspace_id, workspace_id) and std.mem.eql(u8, entry.name, name)) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "a role config with that name already exists" });
            return;
        }
    }

    const id = try model.generateId(allocator, name);
    const now = try nowString();
    const entry = model.RoleConfigEntry{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(name),
        .permissions = try memDup(req.permissions),
        .upgrade_conditions = try memDup(req.upgrade_conditions),
        .level = req.level,
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_role_configs.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.roleConfigResponseFromEntry(entry));
}

pub fn updateRoleConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const role_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "role_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(UpdateRoleConfigRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name) |n| {
        if (model.validateRoleName(n) == null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name is required and must be 64 characters or fewer" });
            return;
        }
    }

    if (deps.hasPool()) {
        if (model.dbUpdateRoleConfig(
            role_id,
            workspace_id,
            req.name orelse "",
            req.permissions orelse "",
            req.upgrade_conditions orelse "",
            if (req.level) |l| l else -1,
        )) |resp| {
            try ctx.renderJson(resp);
            return;
        }
        // DB failed — fall through to in-memory
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_role_configs.?.getPtr(role_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "role config not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "role config not found" });
        return;
    }

    if (req.name) |n| {
        entry.name = try memDup(n);
    }
    if (req.permissions) |p| {
        entry.permissions = try memDup(p);
    }
    if (req.upgrade_conditions) |u| {
        entry.upgrade_conditions = try memDup(u);
    }
    if (req.level) |l| {
        entry.level = l;
    }
    if (req.name != null or req.permissions != null or req.upgrade_conditions != null or req.level != null) {
        entry.updated_at = try nowString();
    }

    try ctx.renderJson(model.roleConfigResponseFromEntry(entry.*));
}

pub fn deleteRoleConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const role_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "role_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbDeleteRoleConfig(role_id, workspace_id)) {
            try response.okNoContent(ctx);
            return;
        }
        // DB failed — fall through to in-memory
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_role_configs.?.fetchRemove(role_id)) |kv| {
        const entry = kv.value;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            try mem_role_configs.?.put(entry.id, entry);
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "role config not found" });
            return;
        }
    }
    try response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// MemberRole — assign, list, get, update, delete
// ──────────────────────────────────────────────────────────────────────

pub fn listMemberRoles(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.MemberRoleResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_member_roles.?.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.*.workspace_id, workspace_id)) continue;
        try list.append(allocator, model.memberRoleResponseFromEntry(e.value_ptr.*));
    }
    try ctx.renderJson(.{ .members = list.items, .total = list.items.len });
}

pub fn getMemberRole(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = ctx.getPathParam("userId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = memberKey(user_id, workspace_id, memAlloc()) catch {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "allocation failed" });
        return;
    };

    const entry = mem_member_roles.?.get(key) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "member role not found" });
        return;
    };
    try ctx.renderJson(model.memberRoleResponseFromEntry(entry));
}

pub fn assignRole(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(AssignRoleRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const role_name = model.validateRoleName(req.role) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "role name is required and must be 64 characters or fewer" });
        return;
    };

    const user_id_trimmed = std.mem.trim(u8, req.user_id, &std.ascii.whitespace);
    if (user_id_trimmed.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // If parent_id is provided, verify it exists in this workspace
    if (req.parent_id) |pid| {
        if (pid.len > 0) {
            const parent_key = memberKey(pid, workspace_id, memAlloc()) catch {
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "allocation failed" });
                return;
            };
            if (mem_member_roles.?.get(parent_key) == null) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "parent member role not found" });
                return;
            }
        }
    }

    const now = try nowString();
    const key = memberKey(user_id_trimmed, workspace_id, memAlloc()) catch {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "allocation failed" });
        return;
    };

    const entry = model.MemberRoleEntry{
        .user_id = try memDup(user_id_trimmed),
        .workspace_id = try memDup(workspace_id),
        .role = try memDup(role_name),
        .level = req.level,
        .parent_id = try memDup(req.parent_id orelse ""),
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_member_roles.?.put(key, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.memberRoleResponseFromEntry(entry));
}

pub fn updateMemberRole(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = ctx.getPathParam("userId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(UpdateMemberRoleRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.role) |r| {
        if (model.validateRoleName(r) == null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "role name must be 64 characters or fewer" });
            return;
        }
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = memberKey(user_id, workspace_id, memAlloc()) catch {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "allocation failed" });
        return;
    };

    const entry = mem_member_roles.?.getPtr(key) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "member role not found" });
        return;
    };

    if (req.role) |r| entry.role = try memDup(r);
    if (req.level) |l| entry.level = l;
    if (req.parent_id) |p| {
        if (p.len > 0) {
            const parent_key = memberKey(p, workspace_id, memAlloc()) catch {
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "allocation failed" });
                return;
            };
            if (mem_member_roles.?.get(parent_key) == null) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "parent member role not found" });
                return;
            }
        }
        entry.parent_id = try memDup(p);
    }
    entry.updated_at = try nowString();

    try ctx.renderJson(model.memberRoleResponseFromEntry(entry.*));
}

pub fn deleteMemberRole(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = ctx.getPathParam("userId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = memberKey(user_id, workspace_id, memAlloc()) catch {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "allocation failed" });
        return;
    };

    if (mem_member_roles.?.fetchRemove(key)) |_| {} else {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "member role not found" });
        return;
    }
    try response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// Hierarchical queries — downline tree & upline chain
// ──────────────────────────────────────────────────────────────────────

/// Collect all descendants of the given user (recursive).
fn collectDownline(allocator: std.mem.Allocator, workspace_id: []const u8, parent_user_id: []const u8, results: *std.ArrayList(model.MemberRoleResponse)) !void {
    var it = mem_member_roles.?.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr.*;
        if (!std.mem.eql(u8, m.workspace_id, workspace_id)) continue;
        if (!std.mem.eql(u8, m.parent_id, parent_user_id)) continue;
        try results.append(allocator, model.memberRoleResponseFromEntry(m));
        try collectDownline(allocator, workspace_id, m.user_id, results);
    }
}

/// Get the full downline (descendant tree) for a member.
pub fn getDownlineTree(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = ctx.getPathParam("userId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.MemberRoleResponse) = .empty;
    defer list.deinit(allocator);
    try collectDownline(allocator, workspace_id, user_id, &list);

    try ctx.renderJson(.{ .downline = list.items, .total = list.items.len });
}

/// Collect all ancestors (upline) for the given user, walking parent_id upwards.
fn collectUpline(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, results: *std.ArrayList(model.MemberRoleResponse)) !void {
    var it = mem_member_roles.?.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr.*;
        if (!std.mem.eql(u8, m.workspace_id, workspace_id)) continue;
        if (!std.mem.eql(u8, m.user_id, user_id)) continue;
        if (m.parent_id.len == 0) return;
        // Find the parent
        var it2 = mem_member_roles.?.iterator();
        while (it2.next()) |e2| {
            const p = e2.value_ptr.*;
            if (!std.mem.eql(u8, p.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, p.user_id, m.parent_id)) continue;
            try results.append(allocator, model.memberRoleResponseFromEntry(p));
            try collectUpline(allocator, workspace_id, p.user_id, results);
            return;
        }
        return;
    }
}

/// Get the full upline (ancestor chain) for a member.
pub fn getUplineChain(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = ctx.getPathParam("userId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.MemberRoleResponse) = .empty;
    defer list.deinit(allocator);
    try collectUpline(allocator, workspace_id, user_id, &list);

    try ctx.renderJson(.{ .upline = list.items, .total = list.items.len });
}
