//! Runtime module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape, request/response DTOs) and
//! the escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic, the per-process state (`mem_runtimes`,
//! `mem_updates`, `mem_models`, `mem_local_skills`,
//! `mem_local_imports`), and the async request stores used by the
//! daemon.
//!
//! The `agent_runtime` table uses UUID PKs and the in-memory request
//! stores have no backing table, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const task_queue = @import("../../task_queue.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

pub fn nowString() ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real);
    const ms = ts.toMilliseconds();
    const sec = @divFloor(ms, 1000);
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

// ──────────────────────────────────────────────────────────────────────
// data structs
// ──────────────────────────────────────────────────────────────────────

pub const RuntimeEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    daemon_id: ?[]const u8,
    name: []const u8,
    runtime_mode: []const u8,
    provider: []const u8,
    status: []const u8,
    device_info: []const u8,
    owner_id: ?[]const u8,
    visibility: []const u8,
    last_seen_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const AgentRuntimeResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    daemon_id: ?[]const u8,
    name: []const u8,
    runtime_mode: []const u8,
    provider: []const u8,
    launch_header: []const u8,
    status: []const u8,
    device_info: []const u8,
    metadata: std.json.Value,
    owner_id: ?[]const u8,
    visibility: []const u8,
    last_seen_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const RuntimeUsageResponse = struct {
    runtime_id: []const u8,
    date: []const u8,
    provider: []const u8,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
};

pub const RuntimeUsageByAgentResponse = struct {
    agent_id: []const u8,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    task_count: i32,
};

pub const RuntimeUsageByHourResponse = struct {
    hour: i32,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    task_count: i32,
};

pub const HourlyActivity = struct {
    hour: i32,
    count: i32,
};

pub const UpdateAgentRuntimeRequest = struct {
    visibility: ?[]const u8 = null,
};

pub const ArchiveAgentsAndDeleteRuntimeRequest = struct {
    expected_active_agent_ids: ?[][]const u8 = null,
};

pub const InitiateUpdateRequest = struct {
    target_version: []const u8,
};

pub const CreateRuntimeLocalSkillImportRequest = struct {
    skill_key: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    action: ?[]const u8 = null,
    target_skill_id: ?[]const u8 = null,
    supports_conflict: bool = false,
};

// ──────────────────────────────────────────────────────────────────────
// in-memory request-store rows
// ──────────────────────────────────────────────────────────────────────

pub const UpdateRequest = struct {
    id: []const u8,
    runtime_id: []const u8,
    status: []const u8,
    target_version: []const u8,
    output: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const ModelEntry = struct {
    id: []const u8,
    label: []const u8,
    provider: ?[]const u8 = null,
    default: bool = false,
    thinking: ?std.json.Value = null,
};

pub const ModelListRequest = struct {
    id: []const u8,
    runtime_id: []const u8,
    status: []const u8,
    models: ?[]const ModelEntry = null,
    supported: bool = true,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const RuntimeLocalSkillSummary = struct {
    key: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    source_path: []const u8,
    provider: []const u8,
    file_count: i32 = 0,
};

pub const RuntimeLocalSkillListRequest = struct {
    id: []const u8,
    runtime_id: []const u8,
    status: []const u8,
    skills: ?[]const RuntimeLocalSkillSummary = null,
    supported: bool = true,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const LocalSkillImportConflict = struct {
    existing_skill_id: []const u8,
    existing_created_by: ?[]const u8 = null,
    can_overwrite: bool = false,
};

pub const RuntimeLocalSkillImportRequest = struct {
    id: []const u8,
    runtime_id: []const u8,
    skill_key: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    action: ?[]const u8 = null,
    target_skill_id: ?[]const u8 = null,
    supports_conflict: bool = false,
    status: []const u8,
    skill: ?std.json.Value = null,
    conflict: ?LocalSkillImportConflict = null,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
    creator_id: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// row / entry → response shape
// ──────────────────────────────────────────────────────────────────────

pub fn runtimeResponseFromEntry(entry: RuntimeEntry) AgentRuntimeResponse {
    return AgentRuntimeResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .daemon_id = entry.daemon_id,
        .name = entry.name,
        .runtime_mode = entry.runtime_mode,
        .provider = entry.provider,
        .launch_header = "",
        .status = entry.status,
        .device_info = entry.device_info,
        .metadata = .{ .object = std.json.ObjectMap.empty },
        .owner_id = entry.owner_id,
        .visibility = entry.visibility,
        .last_seen_at = entry.last_seen_at,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// Like `runtimeResponseFromRow` but deep-copies every string field into
/// `allocator`, so the returned response outlives the result set. Use
/// this when the response is returned from a function whose `ResultSet`
/// is deinitialized before the caller reads the response (e.g.
/// `requireRuntimeAccess`); the borrowing variant is only safe while the
/// result set stays alive (list handlers that render inside the scope).
pub fn runtimeResponseFromRowDuped(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize) AgentRuntimeResponse {
    const r = &rs.rows.items[row];
    return AgentRuntimeResponse{
        .id = dupeText(allocator, r.getText(0)),
        .workspace_id = dupeText(allocator, r.getText(1)),
        .daemon_id = dupeOpt(allocator, r.getText(2)),
        .name = dupeText(allocator, r.getText(3)),
        .runtime_mode = dupeText(allocator, r.getText(4)),
        .provider = dupeText(allocator, r.getText(5)),
        .launch_header = "",
        .status = dupeText(allocator, r.getText(6)),
        .device_info = dupeText(allocator, r.getText(7)),
        .metadata = .{ .object = std.json.ObjectMap.empty },
        .owner_id = dupeOpt(allocator, r.getText(10)),
        .visibility = dupeText(allocator, r.getText(13)),
        .last_seen_at = dupeOpt(allocator, r.getText(9)),
        .created_at = dupeText(allocator, r.getText(11)),
        .updated_at = dupeText(allocator, r.getText(12)),
    };
}

fn dupeText(allocator: std.mem.Allocator, text: ?[]const u8) []const u8 {
    const t = text orelse return "";
    return allocator.dupe(u8, t) catch "";
}

fn dupeOpt(allocator: std.mem.Allocator, text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return allocator.dupe(u8, t) catch null;
}

pub fn runtimeResponseFromRow(rs: *zfinal.ResultSet, row: usize) AgentRuntimeResponse {
    const r = &rs.rows.items[row];
    return AgentRuntimeResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .daemon_id = r.getText(2),
        .name = r.getText(3) orelse "",
        .runtime_mode = r.getText(4) orelse "",
        .provider = r.getText(5) orelse "",
        .launch_header = "",
        .status = r.getText(6) orelse "",
        .device_info = r.getText(7) orelse "",
        .metadata = .{ .object = std.json.ObjectMap.empty },
        .owner_id = r.getText(10),
        .visibility = r.getText(13) orelse "private",
        .last_seen_at = r.getText(9),
        .created_at = r.getText(11) orelse "",
        .updated_at = r.getText(12) orelse "",
    };
}

pub fn canEditRuntime(member_role: ?[]const u8, user_id: []const u8, owner_id: ?[]const u8) bool {
    if (member_role) |role| {
        if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin")) return true;
    }
    if (owner_id) |oid| {
        if (std.mem.eql(u8, oid, user_id)) return true;
    }
    return false;
}

pub fn resolveMemberRole(_ctx: *zfinal.Context, db: *zfinal.DB, workspace_id: []const u8, user_id: []const u8) !?[]const u8 {
    _ = _ctx;
    var rs = try db.queryParams(
        "SELECT role FROM member WHERE workspace_id = $1::uuid AND user_id = $2::uuid",
        &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return rs.rows.items[0].getText(0);
}

/// Fetch a runtime row by id. Returns `null` (with 404 set on `ctx`)
/// when the runtime does not exist.
pub fn requireRuntimeAccess(ctx: *zfinal.Context, db: *zfinal.DB, runtime_id: []const u8) !?AgentRuntimeResponse {
    var rs = try db.queryParams(
        "SELECT * FROM agent_runtime WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = runtime_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "runtime not found" });
        return null;
    }
    // Deep-copy: the ResultSet is deinitialized on return, so the
    // borrowing variant would leave dangling string slices (the caller
    // reads them after this function returns — see the UUUU corruption
    // this previously caused in initiateUpdate).
    return runtimeResponseFromRowDuped(ctx.allocator, &rs, 0);
}

// Re-exported so service.zig can call into the task queue without a
// separate import in the handler / route layer.
pub const TaskQueue = task_queue;
