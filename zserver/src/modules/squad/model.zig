//! Squad module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response) and the escape-hatch SQL
//! helpers. `service.zig` wraps this with the business logic and the
//! in-memory fallback for the no-DB smoke path.

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

/// `squad` row.
pub const SquadEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    instructions: []const u8,
    avatar_url: []const u8,
    leader_id: []const u8,
    creator_id: []const u8,
    archived_at: []const u8,
    archived_by: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// `squad_member` row.
pub const SquadMemberEntry = struct {
    id: []const u8,
    squad_id: []const u8,
    member_type: []const u8,
    member_id: []const u8,
    role: []const u8,
    created_at: []const u8,
};

/// Lightweight summary of a single squad member, embedded in the
/// squad response.
pub const SquadMemberPreview = struct {
    member_type: []const u8,
    member_id: []const u8,
    role: []const u8,
};

/// Full squad response.
pub const SquadResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    instructions: []const u8,
    avatar_url: ?[]const u8,
    leader_id: []const u8,
    creator_id: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    archived_at: ?[]const u8,
    archived_by: ?[]const u8,
    member_count: i32,
    member_preview: []SquadMemberPreview,
};

/// Squad member response (list-of-members endpoint).
pub const SquadMemberResponse = struct {
    id: []const u8,
    squad_id: []const u8,
    member_type: []const u8,
    member_id: []const u8,
    role: []const u8,
    created_at: []const u8,
};

/// Build the embedded `member_preview` list for a squad response.
pub fn squadMemberPreview(allocator: std.mem.Allocator, members: []const SquadMemberEntry) ![]SquadMemberPreview {
    var list: std.ArrayList(SquadMemberPreview) = .empty;
    defer list.deinit(allocator);
    for (members) |m| {
        try list.append(allocator, SquadMemberPreview{
            .member_type = m.member_type,
            .member_id = m.member_id,
            .role = m.role,
        });
    }
    return try list.toOwnedSlice(allocator);
}

/// Convert an in-memory `SquadEntry` plus its member list into a
/// `SquadResponse` for the API.
pub fn squadResponseFromEntry(allocator: std.mem.Allocator, entry: SquadEntry, members: []const SquadMemberEntry) !SquadResponse {
    const preview = try squadMemberPreview(allocator, members);
    return SquadResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .description = entry.description,
        .instructions = entry.instructions,
        .avatar_url = if (entry.avatar_url.len > 0) entry.avatar_url else null,
        .leader_id = entry.leader_id,
        .creator_id = entry.creator_id,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .archived_at = if (entry.archived_at.len > 0) entry.archived_at else null,
        .archived_by = if (entry.archived_by.len > 0) entry.archived_by else null,
        .member_count = @intCast(members.len),
        .member_preview = preview,
    };
}

/// Convert a `SELECT id, workspace_id, name, description, instructions, avatar_url, leader_id, creator_id, created_at, updated_at, archived_at, archived_by FROM squad ...` row plus its member list into a `SquadResponse`.
pub fn squadResponseFromRow(allocator: std.mem.Allocator, rs: zfinal.ResultSet, row: usize, members: []const SquadMemberEntry) !SquadResponse {
    const preview = try squadMemberPreview(allocator, members);
    const r = &rs.rows.items[row];
    return SquadResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .name = r.getText(2) orelse "",
        .description = r.getText(3) orelse "",
        .instructions = r.getText(4) orelse "",
        .avatar_url = r.getText(5),
        .leader_id = r.getText(6) orelse "",
        .creator_id = r.getText(7) orelse "",
        .created_at = r.getText(8) orelse "",
        .updated_at = r.getText(9) orelse "",
        .archived_at = r.getText(10),
        .archived_by = r.getText(11),
        .member_count = @intCast(members.len),
        .member_preview = preview,
    };
}

pub fn squadMemberResponseFromEntry(entry: SquadMemberEntry) SquadMemberResponse {
    return SquadMemberResponse{
        .id = entry.id,
        .squad_id = entry.squad_id,
        .member_type = entry.member_type,
        .member_id = entry.member_id,
        .role = entry.role,
        .created_at = entry.created_at,
    };
}

pub fn squadMemberResponseFromRow(rs: zfinal.ResultSet, row: usize) SquadMemberResponse {
    const r = &rs.rows.items[row];
    return SquadMemberResponse{
        .id = r.getText(0) orelse "",
        .squad_id = r.getText(1) orelse "",
        .member_type = r.getText(2) orelse "",
        .member_id = r.getText(3) orelse "",
        .role = r.getText(4) orelse "",
        .created_at = r.getText(5) orelse "",
    };
}

/// Lightweight UUID-shape check; the DB still enforces the canonical
/// 36-character form on insert.
pub fn looksLikeUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        const c = s[i];
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isAlphanumeric(c)) {
            return false;
        }
    }
    return true;
}

/// `member_type` is restricted to `"agent"` or `"member"`.
pub fn isValidMemberType(t: []const u8) bool {
    return std.mem.eql(u8, t, "agent") or std.mem.eql(u8, t, "member");
}

/// Generate a stable pseudo-UUID for the in-memory store. Mirrors the
/// algorithm used by the legacy `src/handlers/squad.zig`.
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

/// `SELECT id, squad_id, member_type, member_id, role, created_at FROM squad_member WHERE squad_id = $1::uuid ORDER BY created_at ASC`.
pub fn dbMembersForSquad(allocator: std.mem.Allocator, db: *zfinal.DB, squad_id: []const u8) ![]SquadMemberEntry {
    var rs = try db.queryParams(
        "SELECT id, squad_id, member_type, member_id, role, created_at FROM squad_member WHERE squad_id = $1::uuid ORDER BY created_at ASC",
        &[_]SqlParam{.{ .text = squad_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(SquadMemberEntry) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        const r = &rs.rows.items[i];
        try list.append(allocator, SquadMemberEntry{
            .id = r.getText(0) orelse "",
            .squad_id = r.getText(1) orelse "",
            .member_type = r.getText(2) orelse "",
            .member_id = r.getText(3) orelse "",
            .role = r.getText(4) orelse "",
            .created_at = r.getText(5) orelse "",
        });
    }
    return try list.toOwnedSlice(allocator);
}