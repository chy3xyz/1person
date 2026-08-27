//! Skill module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response) and the escape-hatch SQL
//! helpers. `service.zig` wraps this with the business logic and the
//! in-memory fallback for the no-DB smoke path.
//!
//! The skill tables (`skill`, `skill_file`) use UUID PKs with JSONB
//! columns and free-form text, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`. The in-memory fallback
//! uses the `SkillEntry` / `SkillFileEntry` structs defined here so
//! the smoke-test path is exercised when the DB is unconfigured.
//!
//! `agent` (sibling module) imports `memSkillById`,
//! `skillSummaryFromRow`, `skillSummaryFromEntry`, and
//! `SkillSummaryResponse` from this file — these are the public
//! cross-module data helpers that the agent service consumes.

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

/// In-memory `skill` row.
pub const SkillEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    config: []const u8,
    created_by: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `skill_file` row.
pub const SkillFileEntry = struct {
    id: []const u8,
    skill_id: []const u8,
    path: []const u8,
    content: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Response shape for a single `skill` row.
pub const SkillResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    config: std.json.Value,
    created_by: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Lightweight summary used by agent-skill joins (no `content`).
pub const SkillSummaryResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    config: std.json.Value,
    created_by: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Response shape for `skill_file` rows.
pub const SkillFileResponse = struct {
    id: []const u8,
    skill_id: []const u8,
    path: []const u8,
    content: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Skill + files composite response.
pub const SkillWithFilesResponse = struct {
    skill: SkillResponse,
    files: []SkillFileResponse,
};

/// Request body for `POST /api/skills`.
pub const CreateSkillRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    config: ?std.json.Value = null,
    files: ?[]const CreateSkillFileRequest = null,
};

/// Request body for `PATCH /api/skills/:id`.
pub const UpdateSkillRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    config: ?std.json.Value = null,
    files: ?[]const CreateSkillFileRequest = null,
};

/// Request body for the `files` sub-array on create/update.
pub const CreateSkillFileRequest = struct {
    path: []const u8,
    content: []const u8,
};

/// Request body for `POST /api/skills/import`.
pub const ImportSkillRequest = struct {
    url: []const u8,
    on_conflict: ?[]const u8 = null,
};

/// Request body for `PUT /api/skills/:id/files`.
pub const UpsertSkillFileRequest = struct {
    path: []const u8,
    content: []const u8,
};

/// Result of a remote import (used internally by `importSkill`).
pub const ImportedSkill = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    origin: std.json.Value,
};

// ──────────────────────────────────────────────────────────────────────
// in-memory store (lives at module scope so `agent` can read it)
// ──────────────────────────────────────────────────────────────────────

/// Mutex guarding the in-memory `mem_skills` / `mem_skill_files` maps.
pub var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
pub var mem_skills: ?std.StringHashMap(SkillEntry) = null;
pub var mem_skill_files: ?std.StringHashMap(std.ArrayList(SkillFileEntry)) = null;

pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn memInit() !void {
    if (mem_skills == null) {
        mem_skills = std.StringHashMap(SkillEntry).init(memAlloc());
        mem_skill_files = std.StringHashMap(std.ArrayList(SkillFileEntry)).init(memAlloc());
    }
}

pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

pub fn emptyJsonObject(_allocator: std.mem.Allocator) std.json.Value {
    _ = _allocator;
    return .{ .object = std.json.ObjectMap.empty };
}

pub fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8, holder: *?std.json.Parsed(std.json.Value)) !std.json.Value {
    if (text.len == 0) return emptyJsonObject(allocator);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return emptyJsonObject(allocator);
    holder.* = parsed;
    return parsed.value;
}

/// Stable pseudo-UUID for the in-memory store.
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

pub fn stringOrEmpty(s: ?[]const u8) []const u8 {
    return s orelse "";
}

/// Reject absolute paths and `..` segments so a caller can't escape
/// the skill's virtual root.
pub fn validateFilePath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (std.fs.path.isAbsolute(p)) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Look up an in-memory skill by id. Returns `null` for DB-backed
/// skills (which `agent` should fetch via the SQL path).
pub fn memSkillById(id: []const u8) ?SkillEntry {
    if (mem_skills == null) return null;
    return mem_skills.?.get(id);
}

pub fn memFindSkillIdByName(workspace_id: []const u8, name: []const u8) ?[]const u8 {
    if (mem_skills == null) return null;
    var it = mem_skills.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.workspace_id, workspace_id) and std.mem.eql(u8, entry.name, name)) {
            return entry.id;
        }
    }
    return null;
}

pub fn memUniqueSkillName(allocator: std.mem.Allocator, workspace_id: []const u8, base: []const u8) ![]const u8 {
    if (memFindSkillIdByName(workspace_id, base) == null) return allocator.dupe(u8, base);
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ base, i });
        if (memFindSkillIdByName(workspace_id, candidate) == null) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, base);
}

// ──────────────────────────────────────────────────────────────────────
// row / entry → response shape
// ──────────────────────────────────────────────────────────────────────

pub fn skillSummaryFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize) !SkillSummaryResponse {
    var config_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (config_holder) |p| p.deinit();
    const config = try parseJsonValue(allocator, rs.rows.items[row].getText(4) orelse "{}", &config_holder);
    const id = try allocator.dupe(u8, rs.rows.items[row].getText(0) orelse "");
    errdefer allocator.free(id);
    const workspace_id = try allocator.dupe(u8, rs.rows.items[row].getText(1) orelse "");
    errdefer allocator.free(workspace_id);
    const name = try allocator.dupe(u8, rs.rows.items[row].getText(2) orelse "");
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, rs.rows.items[row].getText(3) orelse "");
    errdefer allocator.free(description);
    const created_by_raw = rs.rows.items[row].getText(5);
    var created_by: ?[]const u8 = null;
    if (created_by_raw) |cb| {
        created_by = try allocator.dupe(u8, cb);
        errdefer if (created_by) |d| allocator.free(d);
    }
    const created_at = try allocator.dupe(u8, rs.rows.items[row].getText(6) orelse "");
    errdefer allocator.free(created_at);
    const updated_at = try allocator.dupe(u8, rs.rows.items[row].getText(7) orelse "");
    errdefer allocator.free(updated_at);
    return SkillSummaryResponse{
        .id = id,
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .config = config,
        .created_by = created_by,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn skillSummaryFromEntry(allocator: std.mem.Allocator, entry: SkillEntry) !SkillSummaryResponse {
    var config_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (config_holder) |p| p.deinit();
    const config = try parseJsonValue(allocator, entry.config, &config_holder);
    return SkillSummaryResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .description = entry.description,
        .config = config,
        .created_by = if (entry.created_by.len > 0) entry.created_by else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn skillResponseFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize) !SkillResponse {
    var config_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (config_holder) |p| p.deinit();
    const config = try parseJsonValue(allocator, rs.rows.items[row].getText(6) orelse "{}", &config_holder);
    const id = try allocator.dupe(u8, rs.rows.items[row].getText(0) orelse "");
    errdefer allocator.free(id);
    const workspace_id = try allocator.dupe(u8, rs.rows.items[row].getText(1) orelse "");
    errdefer allocator.free(workspace_id);
    const name = try allocator.dupe(u8, rs.rows.items[row].getText(2) orelse "");
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, rs.rows.items[row].getText(3) orelse "");
    errdefer allocator.free(description);
    const content = try allocator.dupe(u8, rs.rows.items[row].getText(4) orelse "");
    errdefer allocator.free(content);
    const created_by_raw = rs.rows.items[row].getText(5);
    var created_by: ?[]const u8 = null;
    if (created_by_raw) |cb| {
        created_by = try allocator.dupe(u8, cb);
        errdefer if (created_by) |d| allocator.free(d);
    }
    const created_at = try allocator.dupe(u8, rs.rows.items[row].getText(7) orelse "");
    errdefer allocator.free(created_at);
    const updated_at = try allocator.dupe(u8, rs.rows.items[row].getText(8) orelse "");
    errdefer allocator.free(updated_at);
    return SkillResponse{
        .id = id,
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = content,
        .config = config,
        .created_by = created_by,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn skillResponseFromEntry(allocator: std.mem.Allocator, entry: SkillEntry) !SkillResponse {
    var config_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (config_holder) |p| p.deinit();
    const config = try parseJsonValue(allocator, entry.config, &config_holder);
    return SkillResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .description = entry.description,
        .content = entry.content,
        .config = config,
        .created_by = if (entry.created_by.len > 0) entry.created_by else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn skillFileResponseFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize) !SkillFileResponse {
    const id = try allocator.dupe(u8, rs.rows.items[row].getText(0) orelse "");
    errdefer allocator.free(id);
    const skill_id = try allocator.dupe(u8, rs.rows.items[row].getText(1) orelse "");
    errdefer allocator.free(skill_id);
    const path = try allocator.dupe(u8, rs.rows.items[row].getText(2) orelse "");
    errdefer allocator.free(path);
    const content = try allocator.dupe(u8, rs.rows.items[row].getText(3) orelse "");
    errdefer allocator.free(content);
    const created_at = try allocator.dupe(u8, rs.rows.items[row].getText(4) orelse "");
    errdefer allocator.free(created_at);
    const updated_at = try allocator.dupe(u8, rs.rows.items[row].getText(5) orelse "");
    errdefer allocator.free(updated_at);
    return SkillFileResponse{
        .id = id,
        .skill_id = skill_id,
        .path = path,
        .content = content,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn skillFileResponseFromEntry(entry: SkillFileEntry) SkillFileResponse {
    return SkillFileResponse{
        .id = entry.id,
        .skill_id = entry.skill_id,
        .path = entry.path,
        .content = entry.content,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn dbFilesForSkill(allocator: std.mem.Allocator, db: *zfinal.DB, skill_id: []const u8) ![]SkillFileResponse {
    const sql =
        \\SELECT id, skill_id, path, content, created_at, updated_at FROM skill_file
        \\WHERE skill_id = $1::uuid ORDER BY path ASC
    ;
    var rs = try db.queryParams(sql, &[_]SqlParam{.{ .text = skill_id }});
    defer rs.deinit();
    var list: std.ArrayList(SkillFileResponse) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        try list.append(allocator, try skillFileResponseFromRow(allocator, &rs, i));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn memFilesForSkill(allocator: std.mem.Allocator, skill_id: []const u8) ![]SkillFileResponse {
    var list: std.ArrayList(SkillFileResponse) = .empty;
    defer list.deinit(allocator);
    const files = mem_skill_files.?.get(skill_id) orelse return try list.toOwnedSlice(allocator);
    for (files.items) |f| {
        try list.append(allocator, skillFileResponseFromEntry(f));
    }
    return try list.toOwnedSlice(allocator);
}

/// DB-backed lookup: `SELECT id FROM skill WHERE workspace_id = $1
/// AND name = $2`. Returns `null` in no-DB mode (caller falls back to
/// the in-memory path).
pub fn dbFindSkillIdByName(workspace_id: []const u8, name: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    const sql =
        \\SELECT id FROM skill WHERE workspace_id = $1::uuid AND name = $2
    ;
    var rs = try db.queryParams(sql, &[_]SqlParam{
        .{ .text = workspace_id },
        .{ .text = name },
    });
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return try memDup(rs.rows.items[0].getText(0) orelse "");
}
