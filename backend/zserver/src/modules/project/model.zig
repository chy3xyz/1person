//! Project module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.

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

/// `project` row.
pub const ProjectEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    status: []const u8,
    priority: []const u8,
    lead_type: []const u8,
    lead_id: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// API response shape.
pub const ProjectResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    icon: ?[]const u8,
    status: []const u8,
    priority: []const u8,
    lead_type: ?[]const u8,
    lead_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    issue_count: i64,
    done_count: i64,
    resource_count: i64,
};

/// `project_resource` row. Mirrors migration 065.
pub const ResourceEntry = struct {
    id: []const u8,
    project_id: []const u8,
    name: []const u8,
    url: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire DTO for project resources.
pub const ResourceResponse = struct {
    id: []const u8,
    project_id: []const u8,
    name: []const u8,
    url: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub fn resourceResponseFromEntry(entry: ResourceEntry) ResourceResponse {
    return ResourceResponse{
        .id = entry.id,
        .project_id = entry.project_id,
        .name = entry.name,
        .url = if (entry.url.len > 0) entry.url else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn projectResponseFromEntry(entry: ProjectEntry, issue_count: i64, done_count: i64, resource_count: i64) ProjectResponse {
    return ProjectResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .title = entry.title,
        .description = if (entry.description.len > 0) entry.description else null,
        .icon = if (entry.icon.len > 0) entry.icon else null,
        .status = entry.status,
        .priority = entry.priority,
        .lead_type = if (entry.lead_type.len > 0) entry.lead_type else null,
        .lead_id = if (entry.lead_id.len > 0) entry.lead_id else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .issue_count = issue_count,
        .done_count = done_count,
        .resource_count = resource_count,
    };
}

/// Helper: dupe a possibly-null text column into an allocator-owned slice.
fn dupText(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const t = text orelse return null;
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}

/// Helper: dupe a non-null text column into an allocator-owned slice.
fn dupTextReq(allocator: std.mem.Allocator, text: ?[]const u8) ![]const u8 {
    const t = text orelse "";
    return try allocator.dupe(u8, t);
}

/// Build an owned ProjectResponse from a DB row, duplicating all strings
/// so the caller can safely deinit the ResultSet.
pub fn projectResponseFromRowOwned(allocator: std.mem.Allocator, res: *zfinal.ResultSet, row: usize, issue_count: i64, done_count: i64, resource_count: i64) !ProjectResponse {
    const r = &res.rows.items[row];
    return ProjectResponse{
        .id = try dupTextReq(allocator, r.getText(0)),
        .workspace_id = try dupTextReq(allocator, r.getText(1)),
        .title = try dupTextReq(allocator, r.getText(2)),
        .description = try dupText(allocator, r.getText(3)),
        .icon = try dupText(allocator, r.getText(4)),
        .status = try dupTextReq(allocator, r.getText(5)),
        .priority = try dupTextReq(allocator, r.getText(6)),
        .lead_type = try dupText(allocator, r.getText(7)),
        .lead_id = try dupText(allocator, r.getText(8)),
        .created_at = try dupTextReq(allocator, r.getText(9)),
        .updated_at = try dupTextReq(allocator, r.getText(10)),
        .issue_count = issue_count,
        .done_count = done_count,
        .resource_count = resource_count,
    };
}

pub fn isValidStatus(status: []const u8) bool {
    const valid = [_][]const u8{ "planned", "in_progress", "paused", "completed", "cancelled" };
    for (valid) |v| if (std.mem.eql(u8, status, v)) return true;
    return false;
}

pub fn isValidPriority(priority: []const u8) bool {
    const valid = [_][]const u8{ "urgent", "high", "medium", "low", "none" };
    for (valid) |v| if (std.mem.eql(u8, priority, v)) return true;
    return false;
}

pub fn isValidLeadType(t: []const u8) bool {
    return std.mem.eql(u8, t, "member") or std.mem.eql(u8, t, "agent");
}

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

/// Generate a stable pseudo-UUID for the in-memory store. Mirrors the
/// algorithm used by the legacy `src/handlers/project.zig`.
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

/// Aggregate: open / done issue counts for a project. Returns
/// `(total, done)` where `total` is the count of issues NOT in
/// `done` / `cancelled` status (i.e. still open).
pub fn dbLoadIssueStats(project_id: []const u8) struct { total: i64, done: i64 } {
    const db = borrowDb() orelse return .{ .total = 0, .done = 0 };
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT COUNT(*) FILTER (WHERE status NOT IN ('done', 'cancelled')), " ++
            "COUNT(*) FILTER (WHERE status IN ('done', 'cancelled')) FROM issue WHERE project_id = $1::uuid",
        &[_]SqlParam{.{ .text = project_id }},
    ) catch return .{ .total = 0, .done = 0 };
    defer rs.deinit();
    if (rs.rows.items.len == 0) return .{ .total = 0, .done = 0 };
    const total_text = rs.rows.items[0].getText(0) orelse "0";
    const done_text = rs.rows.items[0].getText(1) orelse "0";
    return .{
        .total = std.fmt.parseInt(i64, total_text, 10) catch 0,
        .done = std.fmt.parseInt(i64, done_text, 10) catch 0,
    };
}

/// `SELECT ... FROM project WHERE <filters>` — supports optional
/// `status` / `priority` filters. Returns the list of response rows
/// already enriched with issue-stats and resource-counts. All strings
/// are allocator-owned so the caller owns the returned slice.
pub fn dbListProjects(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    status_filter: ?[]const u8,
    priority_filter: ?[]const u8,
) ![]ProjectResponse {
    const db = borrowDb() orelse return &[_]ProjectResponse{};
    defer deps.releaseBack(db);

    var params: std.ArrayList(SqlParam) = .empty;
    defer {
        for (params.items) |p| allocator.free(p.text);
        params.deinit(allocator);
    }
    try params.append(allocator, .{ .text = try allocator.dupe(u8, workspace_id) });

    var where: std.ArrayList(u8) = .empty;
    defer where.deinit(allocator);
    try where.appendSlice(allocator, "workspace_id = $1::uuid");

    var idx: usize = 1;
    if (status_filter) |s| {
        idx += 1;
        try params.append(allocator, .{ .text = try allocator.dupe(u8, s) });
        const clause = try std.fmt.allocPrint(allocator, " AND status = ${d}", .{idx});
        try where.appendSlice(allocator, clause);
    }
    if (priority_filter) |p| {
        idx += 1;
        try params.append(allocator, .{ .text = try allocator.dupe(u8, p) });
        const clause = try std.fmt.allocPrint(allocator, " AND priority = ${d}", .{idx});
        try where.appendSlice(allocator, clause);
    }

    const query = try std.fmt.allocPrintSentinel(
        allocator,
        "SELECT id, workspace_id, title, description, icon, status, priority, lead_type, lead_id, created_at, updated_at " ++
            "FROM project WHERE {s} ORDER BY created_at ASC",
        .{where.items},
        0,
    );
    defer allocator.free(query);

    var rs = try db.queryParams(query, params.items);
    defer rs.deinit();

    var list: std.ArrayList(ProjectResponse) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        const r = &rs.rows.items[i];
        const id = r.getText(0) orelse "";
        const stats = dbLoadIssueStats(id);
        const rcount = dbCountResources(id);
        try list.append(allocator, try projectResponseFromRowOwned(allocator, &rs, i, stats.total, stats.done, rcount));
    }
    return try list.toOwnedSlice(allocator);
}

/// `SELECT ... FROM project WHERE id = $1 AND workspace_id = $2`.
/// Returns an allocator-owned ProjectResponse; caller must free fields.
pub fn dbGetProject(allocator: std.mem.Allocator, workspace_id: []const u8, project_id: []const u8) !?ProjectResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT id, workspace_id, title, description, icon, status, priority, lead_type, lead_id, created_at, updated_at " ++
            "FROM project WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = project_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const stats = dbLoadIssueStats(project_id);
    const rcount = dbCountResources(project_id);
    const row = try projectResponseFromRowOwned(allocator, &rs, 0, stats.total, stats.done, rcount);
    return row;
}

/// `INSERT INTO project (...) RETURNING ...`.
/// Pass empty strings for nullable optional columns.
/// Returns an allocator-owned ProjectResponse.
pub fn dbCreateProject(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    status: []const u8,
    priority: []const u8,
    lead_type: []const u8,
    lead_id: []const u8,
) !?ProjectResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO project (workspace_id, title, description, icon, status, priority, lead_type, lead_id) " ++
            "VALUES ($1::uuid, $2, $3, NULLIF($4, ''), $5, $6, NULLIF($7, '')::text, NULLIF($8, '')::uuid) " ++
            "RETURNING id, workspace_id, title, description, icon, status, priority, lead_type, lead_id, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = description },
            .{ .text = icon },
            .{ .text = status },
            .{ .text = priority },
            .{ .text = lead_type },
            .{ .text = lead_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = try projectResponseFromRowOwned(allocator, &rs, 0, 0, 0, 0);
    return row;
}

/// `UPDATE project SET ... WHERE id = $1 AND workspace_id = $2 RETURNING ...`.
/// Pass empty strings for fields the caller doesn't want to update.
/// Returns an allocator-owned ProjectResponse.
pub fn dbUpdateProject(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    status: []const u8,
    priority: []const u8,
    lead_type: []const u8,
    lead_id: []const u8,
) !?ProjectResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE project SET " ++
            "title = COALESCE(NULLIF($3, ''), title), " ++
            "description = COALESCE(NULLIF($4, ''), description), " ++
            "icon = COALESCE(NULLIF($5, ''), icon), " ++
            "status = COALESCE(NULLIF($6, ''), status), " ++
            "priority = COALESCE(NULLIF($7, ''), priority), " ++
            "lead_type = COALESCE(NULLIF($8, '')::text, lead_type), " ++
            "lead_id = COALESCE(NULLIF($9, '')::uuid, lead_id), " ++
            "updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id, workspace_id, title, description, icon, status, priority, lead_type, lead_id, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = project_id },
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = description },
            .{ .text = icon },
            .{ .text = status },
            .{ .text = priority },
            .{ .text = lead_type },
            .{ .text = lead_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const stats = dbLoadIssueStats(project_id);
    const rcount = dbCountResources(project_id);
    const row = try projectResponseFromRowOwned(allocator, &rs, 0, stats.total, stats.done, rcount);
    return row;
}

/// `DELETE FROM project WHERE id = $1 AND workspace_id = $2`.
pub fn dbDeleteProject(project_id: []const u8, workspace_id: []const u8) void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        "DELETE FROM project WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = project_id },
            .{ .text = workspace_id },
        },
    ) catch {};
}

// ──────────────────────────────────────────────────────────────────────
// project_resource DB helpers
// ──────────────────────────────────────────────────────────────────────

/// Strip JSON string quotes from a jsonb value read as text.
/// e.g. `"https://example.com"` → `https://example.com`
fn unquoteJsonString(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Build an allocator-owned ResourceResponse from a DB row.
fn resourceResponseFromDBRowOwned(allocator: std.mem.Allocator, res: *zfinal.ResultSet, row: usize) !ResourceResponse {
    const r = &res.rows.items[row];
    const url_raw = r.getText(3);
    const url = if (url_raw) |raw| blk: {
        const unquoted = unquoteJsonString(raw);
        if (unquoted.len > 0) break :blk try allocator.dupe(u8, unquoted);
        break :blk null;
    } else null;
    return ResourceResponse{
        .id = try dupTextReq(allocator, r.getText(0)),
        .project_id = try dupTextReq(allocator, r.getText(1)),
        .name = try dupTextReq(allocator, r.getText(2)),
        .url = url,
        .created_at = try dupTextReq(allocator, r.getText(4)),
        .updated_at = "",
    };
}

/// `SELECT resource_type, resource_ref, ... FROM project_resource WHERE project_id = $1`.
/// Returns allocator-owned slice.
pub fn dbListResources(allocator: std.mem.Allocator, project_id: []const u8) ![]ResourceResponse {
    const db = borrowDb() orelse return &[_]ResourceResponse{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT id, project_id, resource_type, resource_ref, created_at " ++
            "FROM project_resource WHERE project_id = $1::uuid " ++
            "ORDER BY position ASC, created_at ASC",
        &[_]SqlParam{.{ .text = project_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(ResourceResponse) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        try list.append(allocator, try resourceResponseFromDBRowOwned(allocator, &rs, i));
    }
    return try list.toOwnedSlice(allocator);
}

/// `INSERT INTO project_resource (...) RETURNING ...`.
/// Maps `name` → `resource_type`, `url` → `resource_ref` (jsonb).
/// Returns allocator-owned ResourceResponse.
pub fn dbCreateResource(allocator: std.mem.Allocator, project_id: []const u8, workspace_id: []const u8, name: []const u8, url: []const u8) !?ResourceResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO project_resource (project_id, workspace_id, resource_type, resource_ref) " ++
            "VALUES ($1::uuid, $2::uuid, $3, to_jsonb($4::text)) " ++
            "RETURNING id, project_id, resource_type, resource_ref, created_at",
        &[_]SqlParam{
            .{ .text = project_id },
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = url },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = try resourceResponseFromDBRowOwned(allocator, &rs, 0);
    return row;
}

/// `UPDATE project_resource SET resource_ref = ..., resource_type = ... WHERE id = $1 RETURNING ...`.
/// Returns allocator-owned ResourceResponse.
pub fn dbUpdateResource(allocator: std.mem.Allocator, resource_id: []const u8, name: []const u8, url: []const u8) !?ResourceResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE project_resource SET resource_ref = to_jsonb($2::text), resource_type = $3 " ++
            "WHERE id = $1::uuid " ++
            "RETURNING id, project_id, resource_type, resource_ref, created_at",
        &[_]SqlParam{
            .{ .text = resource_id },
            .{ .text = url },
            .{ .text = name },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = try resourceResponseFromDBRowOwned(allocator, &rs, 0);
    return row;
}

/// `DELETE FROM project_resource WHERE id = $1`.
pub fn dbDeleteResource(resource_id: []const u8) void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        "DELETE FROM project_resource WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = resource_id }},
    ) catch {};
}

/// `SELECT COUNT(*) FROM project_resource WHERE project_id = $1`.
pub fn dbCountResources(project_id: []const u8) i64 {
    const db = borrowDb() orelse return 0;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT COUNT(*) FROM project_resource WHERE project_id = $1::uuid",
        &[_]SqlParam{.{ .text = project_id }},
    ) catch return 0;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return 0;
    const text = rs.rows.items[0].getText(0) orelse "0";
    return std.fmt.parseInt(i64, text, 10) catch 0;
}
