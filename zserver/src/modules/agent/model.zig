//! Agent module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape, request/response DTOs) and
//! the escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic and the in-memory fallback for the no-DB smoke
//! path.
//!
//! The `agent` table uses UUID PKs with JSONB columns and a custom
//! env map, so all SQL goes through `zfinal.SqlParam` via
//! `deps.acquire()`. The in-memory fallback uses the `AgentEntry`
//! struct defined here so the smoke-test path is exercised when the
//! DB is unconfigured.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const skill = @import("../skill/model.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// In-memory `agent` row.
pub const AgentEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    runtime_id: []const u8,
    name: []const u8,
    description: []const u8,
    instructions: []const u8,
    avatar_url: []const u8,
    runtime_mode: []const u8,
    runtime_config: []const u8,
    custom_args: []const u8,
    custom_env: []const u8,
    mcp_config: []const u8,
    visibility: []const u8,
    status: []const u8,
    max_concurrent_tasks: i32,
    model: []const u8,
    thinking_level: []const u8,
    owner_id: []const u8,
    archived_at: []const u8,
    archived_by: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Agent response — wraps a single agent with the embedded skill
/// summaries.
pub const AgentResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    runtime_id: []const u8,
    name: []const u8,
    description: []const u8,
    instructions: []const u8,
    avatar_url: ?[]const u8,
    runtime_mode: []const u8,
    runtime_config: std.json.Value,
    custom_args: []const []const u8,
    mcp_config: ?std.json.Value,
    has_custom_env: bool,
    custom_env_key_count: i32,
    mcp_config_redacted: bool,
    visibility: []const u8,
    status: []const u8,
    max_concurrent_tasks: i32,
    model: []const u8,
    thinking_level: []const u8,
    owner_id: ?[]const u8,
    skills: []skill.SkillSummaryResponse,
    created_at: []const u8,
    updated_at: []const u8,
    archived_at: ?[]const u8,
    archived_by: ?[]const u8,
};

/// Request body for `POST /api/agents`.
pub const CreateAgentRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
    runtime_id: []const u8,
    runtime_config: ?std.json.Value = null,
    custom_env: ?std.json.Value = null,
    custom_args: ?[]const []const u8 = null,
    mcp_config: ?std.json.Value = null,
    visibility: ?[]const u8 = null,
    max_concurrent_tasks: ?i32 = null,
    model: ?[]const u8 = null,
    thinking_level: ?[]const u8 = null,
    template: ?[]const u8 = null,
};

/// Request body for `PATCH /api/agents/:id`.
pub const UpdateAgentRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
    runtime_id: ?[]const u8 = null,
    runtime_config: ?std.json.Value = null,
    custom_args: ?[]const []const u8 = null,
    mcp_config: ?std.json.Value = null,
    custom_env: ?std.json.Value = null,
    visibility: ?[]const u8 = null,
    status: ?[]const u8 = null,
    max_concurrent_tasks: ?i32 = null,
    model: ?[]const u8 = null,
    thinking_level: ?[]const u8 = null,
};

/// Request body for `PUT /api/agents/:id/skills`.
pub const SetAgentSkillsRequest = struct {
    skill_ids: []const []const u8,
};

/// Response body for `POST /api/agents/:id/cancel-tasks`.
pub const CancelTasksResponse = struct {
    cancelled: i32,
};

/// One per-agent daily bucket of the workspace activity sparkline.
/// Mirrors the Go `AgentActivityBucket`.
pub const AgentActivityBucket = struct {
    agent_id: []const u8,
    bucket_at: []const u8,
    task_count: i32,
    failed_count: i32,
};

/// Trailing-30-day total run count per agent (Agents-list RUNS column).
/// Mirrors the Go `AgentRunCount`.
pub const AgentRunCount = struct {
    agent_id: []const u8,
    run_count: i32,
};

/// One row of `GET /api/agents/:id/tasks`. Mirrors the subset of the
/// frontend `AgentTask` interface that `agent_task_queue` actually
/// stores (the Go handler joins in runtime/chat/autopilot metadata,
/// which zserver does not resolve yet — `runtime_id` is left empty).
pub const TaskResponse = struct {
    id: []const u8,
    agent_id: []const u8,
    runtime_id: []const u8 = "",
    issue_id: []const u8,
    status: []const u8,
    priority: i32,
    dispatched_at: ?[]const u8 = null,
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
};

/// Response body for `GET/PUT /api/agents/:id/env`.
pub const AgentEnvResponse = struct {
    agent_id: []const u8,
    custom_env: std.json.Value,
};

/// Request body for `PUT /api/agents/:id/env`.
pub const UpdateAgentEnvRequest = struct {
    custom_env: std.json.Value,
};

// ──────────────────────────────────────────────────────────────────────
// in-memory store
// ──────────────────────────────────────────────────────────────────────

/// Mutex guarding the in-memory agent/skill-ref maps.
pub var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
pub var mem_agents: ?std.StringHashMap(AgentEntry) = null;
pub var mem_agent_skills: ?std.StringHashMap(std.ArrayList([]const u8)) = null;

pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn memInit() !void {
    if (mem_agents == null) {
        mem_agents = std.StringHashMap(AgentEntry).init(memAlloc());
        mem_agent_skills = std.StringHashMap(std.ArrayList([]const u8)).init(memAlloc());
    }
}

pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

pub fn stringOrEmpty(s: ?[]const u8) []const u8 {
    return s orelse "";
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

pub fn jsonObjectKeyCount(v: std.json.Value) i32 {
    switch (v) {
        .object => |o| return @intCast(o.count()),
        else => return 0,
    }
}

pub fn jsonValueToString(allocator: std.mem.Allocator, v: ?std.json.Value, default: []const u8) ![]const u8 {
    const value = v orelse return allocator.dupe(u8, default);
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
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

pub fn isValidVisibility(v: []const u8) bool {
    return std.mem.eql(u8, v, "workspace") or std.mem.eql(u8, v, "private");
}

pub fn isValidStatus(s: []const u8) bool {
    const valid = [_][]const u8{ "idle", "working", "blocked", "error", "offline" };
    for (valid) |v| if (std.mem.eql(u8, s, v)) return true;
    return false;
}

pub fn isValidRuntimeMode(m: []const u8) bool {
    return std.mem.eql(u8, m, "local") or std.mem.eql(u8, m, "cloud");
}

/// `agent` row column list used by both SELECT and RETURNING clauses.
pub fn agentColumns() []const u8 {
    return "id, workspace_id, runtime_id, name, description, instructions, avatar_url, runtime_mode, " ++
        "runtime_config, custom_args, custom_env, mcp_config, visibility, status, max_concurrent_tasks, " ++
        "model, thinking_level, owner_id, archived_at, created_at, updated_at, archived_by";
}

// ──────────────────────────────────────────────────────────────────────
// row / entry → response shape
// ──────────────────────────────────────────────────────────────────────

pub fn agentResponseFromEntry(allocator: std.mem.Allocator, entry: AgentEntry, skills: []skill.SkillSummaryResponse) !AgentResponse {
    var runtime_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (runtime_holder) |p| p.deinit();
    var mcp_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (mcp_holder) |p| p.deinit();
    var args_holder: ?std.json.Parsed([]const []const u8) = null;
    defer if (args_holder) |p| p.deinit();
    var env_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (env_holder) |p| p.deinit();

    const runtime_config = try parseJsonValue(allocator, entry.runtime_config, &runtime_holder);
    const custom_args = blk: {
        const parsed = std.json.parseFromSlice([]const []const u8, allocator, entry.custom_args, .{}) catch break :blk &[_][]const u8{};
        args_holder = parsed;
        break :blk parsed.value;
    };
    const custom_env = try parseJsonValue(allocator, entry.custom_env, &env_holder);
    const mcp_config = if (entry.mcp_config.len > 0) try parseJsonValue(allocator, entry.mcp_config, &mcp_holder) else null;

    return AgentResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .runtime_id = entry.runtime_id,
        .name = entry.name,
        .description = entry.description,
        .instructions = entry.instructions,
        .avatar_url = if (entry.avatar_url.len > 0) entry.avatar_url else null,
        .runtime_mode = entry.runtime_mode,
        .runtime_config = runtime_config,
        .custom_args = custom_args,
        .mcp_config = mcp_config,
        .has_custom_env = jsonObjectKeyCount(custom_env) > 0,
        .custom_env_key_count = jsonObjectKeyCount(custom_env),
        .mcp_config_redacted = mcp_config == null and entry.mcp_config.len > 0,
        .visibility = entry.visibility,
        .status = entry.status,
        .max_concurrent_tasks = entry.max_concurrent_tasks,
        .model = entry.model,
        .thinking_level = entry.thinking_level,
        .owner_id = if (entry.owner_id.len > 0) entry.owner_id else null,
        .skills = skills,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .archived_at = if (entry.archived_at.len > 0) entry.archived_at else null,
        .archived_by = if (entry.archived_by.len > 0) entry.archived_by else null,
    };
}

pub fn agentResponseFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize, skills: []skill.SkillSummaryResponse) !AgentResponse {
    const id = rs.rows.items[row].getText(0) orelse "";
    const runtime_config_text = rs.rows.items[row].getText(8) orelse "{}";
    const custom_args_text = rs.rows.items[row].getText(9) orelse "[]";
    const custom_env_text = rs.rows.items[row].getText(10) orelse "{}";
    const mcp_text = rs.rows.items[row].getText(11) orelse "";

    var runtime_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (runtime_holder) |p| p.deinit();
    var args_holder: ?std.json.Parsed([]const []const u8) = null;
    defer if (args_holder) |p| p.deinit();
    var env_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (env_holder) |p| p.deinit();
    var mcp_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (mcp_holder) |p| p.deinit();

    const runtime_config = try parseJsonValue(allocator, runtime_config_text, &runtime_holder);
    const custom_args = blk: {
        const parsed = std.json.parseFromSlice([]const []const u8, allocator, custom_args_text, .{}) catch break :blk &[_][]const u8{};
        args_holder = parsed;
        break :blk parsed.value;
    };
    const custom_env = try parseJsonValue(allocator, custom_env_text, &env_holder);
    const mcp_config = if (mcp_text.len > 0) try parseJsonValue(allocator, mcp_text, &mcp_holder) else null;

    const max_tasks_text = rs.rows.items[row].getText(14) orelse "6";
    const max_tasks: i32 = @intCast(std.fmt.parseInt(i64, max_tasks_text, 10) catch 6);

    return AgentResponse{
        .id = id,
        .workspace_id = rs.rows.items[row].getText(1) orelse "",
        .runtime_id = rs.rows.items[row].getText(2) orelse "",
        .name = rs.rows.items[row].getText(3) orelse "",
        .description = rs.rows.items[row].getText(4) orelse "",
        .instructions = rs.rows.items[row].getText(5) orelse "",
        .avatar_url = rs.rows.items[row].getText(6),
        .runtime_mode = rs.rows.items[row].getText(7) orelse "",
        .runtime_config = runtime_config,
        .custom_args = custom_args,
        .mcp_config = mcp_config,
        .has_custom_env = jsonObjectKeyCount(custom_env) > 0,
        .custom_env_key_count = jsonObjectKeyCount(custom_env),
        .mcp_config_redacted = false,
        .visibility = rs.rows.items[row].getText(12) orelse "private",
        .status = rs.rows.items[row].getText(13) orelse "offline",
        .max_concurrent_tasks = max_tasks,
        .model = rs.rows.items[row].getText(15) orelse "",
        .thinking_level = rs.rows.items[row].getText(16) orelse "",
        .owner_id = rs.rows.items[row].getText(17),
        .skills = skills,
        .created_at = rs.rows.items[row].getText(19) orelse "",
        .updated_at = rs.rows.items[row].getText(20) orelse "",
        .archived_at = rs.rows.items[row].getText(18),
        .archived_by = rs.rows.items[row].getText(21),
    };
}

pub fn agentEntryFromRow(rs: *zfinal.ResultSet, row: usize) AgentEntry {
    const max_tasks_text = rs.rows.items[row].getText(14) orelse "6";
    const max_tasks: i32 = @intCast(std.fmt.parseInt(i64, max_tasks_text, 10) catch 6);
    return AgentEntry{
        .id = rs.rows.items[row].getText(0) orelse "",
        .workspace_id = rs.rows.items[row].getText(1) orelse "",
        .runtime_id = rs.rows.items[row].getText(2) orelse "",
        .name = rs.rows.items[row].getText(3) orelse "",
        .description = rs.rows.items[row].getText(4) orelse "",
        .instructions = rs.rows.items[row].getText(5) orelse "",
        .avatar_url = rs.rows.items[row].getText(6) orelse "",
        .runtime_mode = rs.rows.items[row].getText(7) orelse "",
        .runtime_config = rs.rows.items[row].getText(8) orelse "{}",
        .custom_args = rs.rows.items[row].getText(9) orelse "[]",
        .custom_env = rs.rows.items[row].getText(10) orelse "{}",
        .mcp_config = rs.rows.items[row].getText(11) orelse "",
        .visibility = rs.rows.items[row].getText(12) orelse "private",
        .status = rs.rows.items[row].getText(13) orelse "offline",
        .max_concurrent_tasks = max_tasks,
        .model = rs.rows.items[row].getText(15) orelse "",
        .thinking_level = rs.rows.items[row].getText(16) orelse "",
        .owner_id = rs.rows.items[row].getText(17) orelse "",
        .archived_at = rs.rows.items[row].getText(18) orelse "",
        .archived_by = rs.rows.items[row].getText(21) orelse "",
        .created_at = rs.rows.items[row].getText(19) orelse "",
        .updated_at = rs.rows.items[row].getText(20) orelse "",
    };
}

/// Same as agentEntryFromRow but duplicates all string fields with the
/// supplied allocator so the entry outlives the ResultSet.
pub fn agentEntryFromRowDuped(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize) !AgentEntry {
    const max_tasks_text = rs.rows.items[row].getText(14) orelse "6";
    const max_tasks: i32 = @intCast(std.fmt.parseInt(i64, max_tasks_text, 10) catch 6);
    return AgentEntry{
        .id = try allocator.dupe(u8, rs.rows.items[row].getText(0) orelse ""),
        .workspace_id = try allocator.dupe(u8, rs.rows.items[row].getText(1) orelse ""),
        .runtime_id = try allocator.dupe(u8, rs.rows.items[row].getText(2) orelse ""),
        .name = try allocator.dupe(u8, rs.rows.items[row].getText(3) orelse ""),
        .description = try allocator.dupe(u8, rs.rows.items[row].getText(4) orelse ""),
        .instructions = try allocator.dupe(u8, rs.rows.items[row].getText(5) orelse ""),
        .avatar_url = try allocator.dupe(u8, rs.rows.items[row].getText(6) orelse ""),
        .runtime_mode = try allocator.dupe(u8, rs.rows.items[row].getText(7) orelse ""),
        .runtime_config = try allocator.dupe(u8, rs.rows.items[row].getText(8) orelse "{}"),
        .custom_args = try allocator.dupe(u8, rs.rows.items[row].getText(9) orelse "[]"),
        .custom_env = try allocator.dupe(u8, rs.rows.items[row].getText(10) orelse "{}"),
        .mcp_config = try allocator.dupe(u8, rs.rows.items[row].getText(11) orelse ""),
        .visibility = try allocator.dupe(u8, rs.rows.items[row].getText(12) orelse "private"),
        .status = try allocator.dupe(u8, rs.rows.items[row].getText(13) orelse "offline"),
        .max_concurrent_tasks = max_tasks,
        .model = try allocator.dupe(u8, rs.rows.items[row].getText(15) orelse ""),
        .thinking_level = try allocator.dupe(u8, rs.rows.items[row].getText(16) orelse ""),
        .owner_id = try allocator.dupe(u8, rs.rows.items[row].getText(17) orelse ""),
        .archived_at = try allocator.dupe(u8, rs.rows.items[row].getText(18) orelse ""),
        .archived_by = try allocator.dupe(u8, rs.rows.items[row].getText(21) orelse ""),
        .created_at = try allocator.dupe(u8, rs.rows.items[row].getText(19) orelse ""),
        .updated_at = try allocator.dupe(u8, rs.rows.items[row].getText(20) orelse ""),
    };
}

// ──────────────────────────────────────────────────────────────────────
// cross-module helpers (DB + mem skill lookup)
// ──────────────────────────────────────────────────────────────────────

pub fn dbSkillsForAgent(allocator: std.mem.Allocator, db: *zfinal.DB, agent_id: []const u8) ![]skill.SkillSummaryResponse {
    const sql =
        \\SELECT s.id, s.workspace_id, s.name, s.description, s.config, s.created_by, s.created_at, s.updated_at
        \\FROM skill s
        \\JOIN agent_skill aks ON aks.skill_id = s.id
        \\WHERE aks.agent_id = $1::uuid ORDER BY s.name ASC
    ;
    var rs = try db.queryParams(sql, &[_]SqlParam{.{ .text = agent_id }});
    defer rs.deinit();
    var list: std.ArrayList(skill.SkillSummaryResponse) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        try list.append(allocator, try skill.skillSummaryFromRow(allocator, &rs, i));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn memSkillsForAgent(allocator: std.mem.Allocator, agent_id: []const u8) ![]skill.SkillSummaryResponse {
    var list: std.ArrayList(skill.SkillSummaryResponse) = .empty;
    defer list.deinit(allocator);
    const refs = mem_agent_skills.?.get(agent_id) orelse return try list.toOwnedSlice(allocator);
    for (refs.items) |skill_id| {
        const s = skill.memSkillById(skill_id) orelse continue;
        try list.append(allocator, try skill.skillSummaryFromEntry(allocator, s));
    }
    return try list.toOwnedSlice(allocator);
}

/// `SELECT 1 FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid` —
/// used by `setAgentSkills` / `addAgentSkills` to validate that the
/// caller only attaches skills the workspace owns.
pub fn validateSkillIdsInWorkspace(db: *zfinal.DB, workspace_id: []const u8, skill_ids: []const []const u8) !bool {
    const sql =
        \\SELECT 1 FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
    ;
    for (skill_ids) |sid| {
        if (sid.len == 0 or !looksLikeUuid(sid)) return false;
        var rs = try db.queryParams(sql, &[_]SqlParam{
            .{ .text = sid },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) return false;
    }
    return true;
}

pub fn customEnvFromEntry(entry: AgentEntry) std.json.Value {
    var holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (holder) |p| p.deinit();
    return parseJsonValue(memAlloc(), entry.custom_env, &holder) catch emptyJsonObject(memAlloc());
}

/// `SELECT runtime_mode, provider FROM agent_runtime WHERE id = $1::uuid
/// AND workspace_id = $2::uuid`. Returns `null` if the runtime is
/// missing or doesn't belong to the workspace.
pub fn validateRuntime(db: *zfinal.DB, runtime_id: []const u8, workspace_id: []const u8) !?struct { runtime_mode: []const u8, provider: []const u8 } {
    const sql =
        \\SELECT runtime_mode, provider FROM agent_runtime
        \\WHERE id = $1::uuid AND workspace_id = $2::uuid
    ;
    var rs = try db.queryParams(sql, &[_]SqlParam{
        .{ .text = runtime_id },
        .{ .text = workspace_id },
    });
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return .{
        .runtime_mode = rs.rows.items[0].getText(0) orelse "local",
        .provider = rs.rows.items[0].getText(1) orelse "",
    };
}
