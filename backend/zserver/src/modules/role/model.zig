//! Role module — data layer.
//!
//! Holds the data structs for RoleConfig (role definitions) and
//! MemberRole (user assignments with hierarchical parent_id),
//! plus validation helpers and escape-hatch DB helpers.
//! `service.zig` wraps this with business logic + in-memory fallback.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

// ──────────────────────────────────────────────────────────────────────
// RoleConfig — a named role definition with permissions and upgrade
// conditions.  Mirrors the DB table `role_config`.
// ──────────────────────────────────────────────────────────────────────

pub const RoleConfigEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    permissions: []const u8,   // comma-separated list
    upgrade_conditions: []const u8, // comma-separated list
    level: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const RoleConfigResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    permissions: []const u8,
    upgrade_conditions: []const u8,
    level: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

pub fn roleConfigResponseFromEntry(entry: RoleConfigEntry) RoleConfigResponse {
    return RoleConfigResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .permissions = entry.permissions,
        .upgrade_conditions = entry.upgrade_conditions,
        .level = entry.level,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn roleConfigResponseFromRow(res: *zfinal.ResultSet, row: usize) RoleConfigResponse {
    const r = &res.rows.items[row];
    const level_text = r.getText(4) orelse "0";
    return RoleConfigResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .name = r.getText(2) orelse "",
        .permissions = r.getText(3) orelse "",
        .upgrade_conditions = r.getText(5) orelse "",
        .level = std.fmt.parseInt(i64, level_text, 10) catch 0,
        .created_at = r.getText(6) orelse "",
        .updated_at = r.getText(7) orelse "",
    };
}

pub fn roleConfigResponseFromRowDuped(allocator: std.mem.Allocator, res: *zfinal.ResultSet, row: usize) ?RoleConfigResponse {
    const r = &res.rows.items[row];
    const dup_id = allocator.dupe(u8, r.getText(0) orelse "") catch return null;
    errdefer allocator.free(dup_id);
    const dup_ws = allocator.dupe(u8, r.getText(1) orelse "") catch return null;
    errdefer allocator.free(dup_ws);
    const dup_name = allocator.dupe(u8, r.getText(2) orelse "") catch return null;
    errdefer allocator.free(dup_name);
    const dup_perm = allocator.dupe(u8, r.getText(3) orelse "") catch return null;
    errdefer allocator.free(dup_perm);
    const level_text = r.getText(4) orelse "0";
    const level = std.fmt.parseInt(i64, level_text, 10) catch 0;
    const dup_upgrade = allocator.dupe(u8, r.getText(5) orelse "") catch return null;
    errdefer allocator.free(dup_upgrade);
    const dup_ca = allocator.dupe(u8, r.getText(6) orelse "") catch return null;
    errdefer allocator.free(dup_ca);
    const dup_ua = allocator.dupe(u8, r.getText(7) orelse "") catch return null;
    return RoleConfigResponse{
        .id = dup_id,
        .workspace_id = dup_ws,
        .name = dup_name,
        .permissions = dup_perm,
        .upgrade_conditions = dup_upgrade,
        .level = level,
        .created_at = dup_ca,
        .updated_at = dup_ua,
    };
}

pub fn freeRoleConfigResponse(allocator: std.mem.Allocator, resp: RoleConfigResponse) void {
    allocator.free(@constCast(resp.id));
    allocator.free(@constCast(resp.workspace_id));
    allocator.free(@constCast(resp.name));
    allocator.free(@constCast(resp.permissions));
    allocator.free(@constCast(resp.upgrade_conditions));
    allocator.free(@constCast(resp.created_at));
    allocator.free(@constCast(resp.updated_at));
}

// ──────────────────────────────────────────────────────────────────────
// MemberRole — a user's assigned role inside a workspace, with
// hierarchical parent_id for tree structures.
// ──────────────────────────────────────────────────────────────────────

pub const MemberRoleEntry = struct {
    user_id: []const u8,
    workspace_id: []const u8,
    role: []const u8,          // role name (references RoleConfig.name)
    level: i64,
    parent_id: []const u8,     // empty string if no parent
    created_at: []const u8,
    updated_at: []const u8,
};

pub const MemberRoleResponse = struct {
    user_id: []const u8,
    workspace_id: []const u8,
    role: []const u8,
    level: i64,
    parent_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub fn memberRoleResponseFromEntry(entry: MemberRoleEntry) MemberRoleResponse {
    return MemberRoleResponse{
        .user_id = entry.user_id,
        .workspace_id = entry.workspace_id,
        .role = entry.role,
        .level = entry.level,
        .parent_id = if (entry.parent_id.len > 0) entry.parent_id else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// Validate a role name. Returns trimmed name or null if invalid.
pub fn validateRoleName(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (trimmed.len > 64) return null;
    return trimmed;
}

/// Generate a stable pseudo-UUID for the in-memory store.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 36);
    const charset = "0123456789abcdef";
    var o: usize = 0;
    for (hash[0..16], 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            hex[o] = '-';
            o += 1;
        }
        hex[o] = charset[b >> 4];
        hex[o + 1] = charset[b & 0x0f];
        o += 2;
    }
    return hex;
}

// ──────────────────────────────────────────────────────────────────────
// DB helpers for RoleConfig
// ──────────────────────────────────────────────────────────────────────

pub fn dbListRoleConfigs(allocator: std.mem.Allocator, workspace_id: []const u8) ![]RoleConfigResponse {
    const db = borrowDb() orelse return &[_]RoleConfigResponse{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT id, workspace_id, name, permissions, level, upgrade_conditions, created_at, updated_at FROM role_config WHERE workspace_id = $1::uuid ORDER BY level ASC, name ASC",
        &[_]SqlParam{.{ .text = workspace_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(RoleConfigResponse) = .empty;
    errdefer {
        for (list.items) |item| freeRoleConfigResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = roleConfigResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn dbGetRoleConfig(workspace_id: []const u8, role_id: []const u8) ?RoleConfigResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT id, workspace_id, name, permissions, level, upgrade_conditions, created_at, updated_at FROM role_config WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = role_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return roleConfigResponseFromRowDuped(db.allocator, &rs, 0);
}

pub fn dbCreateRoleConfig(workspace_id: []const u8, name: []const u8, permissions: []const u8, upgrade_conditions: []const u8, level: i64) ?RoleConfigResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO role_config (workspace_id, name, permissions, level, upgrade_conditions) VALUES ($1::uuid, $2, $3, $4, $5) " ++
            "RETURNING id, workspace_id, name, permissions, level, upgrade_conditions, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = permissions },
            .{ .int = level },
            .{ .text = upgrade_conditions },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return roleConfigResponseFromRowDuped(db.allocator, &rs, 0);
}

pub fn dbUpdateRoleConfig(role_id: []const u8, workspace_id: []const u8, name: []const u8, permissions: []const u8, upgrade_conditions: []const u8, level: i64) ?RoleConfigResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE role_config SET " ++
            "name = COALESCE(NULLIF($3, ''), name), " ++
            "permissions = COALESCE(NULLIF($4, ''), permissions), " ++
            "upgrade_conditions = COALESCE(NULLIF($5, ''), upgrade_conditions), " ++
            "level = CASE WHEN $6 = -1 THEN level ELSE $6 END, " ++
            "updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id, workspace_id, name, permissions, level, upgrade_conditions, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = role_id },
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = permissions },
            .{ .text = upgrade_conditions },
            .{ .int = level },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return roleConfigResponseFromRowDuped(db.allocator, &rs, 0);
}

pub fn dbDeleteRoleConfig(role_id: []const u8, workspace_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "DELETE FROM role_config WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING id",
        &[_]SqlParam{
            .{ .text = role_id },
            .{ .text = workspace_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}
