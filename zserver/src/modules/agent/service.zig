//! Agent module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_agents`
//! and `mem_agent_skills` tables) and exposes the eleven HTTP-facing
//! operations: `listAgents`, `getAgent`, `createAgent`, `updateAgent`,
//! `archiveAgent`, `restoreAgent`, `cancelTasks`, `getEnv`, `setEnv`,
//! `listAgentSkills`, `setAgentSkills`, `addAgentSkills`, plus the
//! `loadAgent` helper. The `handler.zig` is a thin delegate; SQL and
//! data shapes live in `model.zig`. The `skill` sibling module
//! contributes `memSkillById` / `SkillSummaryResponse` /
//! `skillSummaryFromRow` / `skillSummaryFromEntry` for agent-skill
//! joins.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");

const log = std.log.scoped(.agent_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

fn requireManager(ctx: *zfinal.Context, owner_id: []const u8) !bool {
    const role = getWorkspaceRole(ctx) orelse "";
    if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin")) return true;
    const user_id = getUserId(ctx) orelse "";
    if (std.mem.eql(u8, user_id, owner_id)) return true;
    ctx.res_status = .forbidden;
    try ctx.renderJson(.{ .@"error" = "only the agent owner or workspace admin can manage this agent" });
    return false;
}

fn loadAgent(allocator: std.mem.Allocator, workspace_id: []const u8, agent_id: []const u8) !?model.AgentEntry {
    if (!model.looksLikeUuid(agent_id)) return null;
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const query = try std.fmt.allocPrintSentinel(allocator, "SELECT {s} FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid", .{model.agentColumns()}, 0);
        defer allocator.free(query);
        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        return try model.agentEntryFromRowDuped(allocator, &rs, 0);
    } else {
        try model.memInit();
        const entry = model.mem_agents.?.get(agent_id) orelse return null;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
        return entry;
    }
}

fn mergeAgentEnv(allocator: std.mem.Allocator, existing: std.json.Value, request: std.json.Value) !std.json.Value {
    var merged = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

    if (existing == .object) {
        var it = existing.object.iterator();
        while (it.next()) |kv| {
            try merged.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        }
    }

    if (request == .object) {
        var it = request.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const value = kv.value_ptr.*;
            const is_sentinel = value == .string and std.mem.eql(u8, value.string, "****");
            if (is_sentinel) {
                if (existing == .object and existing.object.contains(key)) {
                    const existing_value = existing.object.get(key).?;
                    try merged.put(allocator, key, existing_value);
                }
                continue;
            }
            try merged.put(allocator, key, value);
        }
    }

    return .{ .object = merged };
}

// ──────────────────────────────────────────────────────────────────────
// list / get
// ──────────────────────────────────────────────────────────────────────

pub fn listAgents(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const include_archived = ctx.getPara("include_archived") catch null;
    const archived_clause = if (include_archived != null and std.mem.eql(u8, include_archived.?, "true")) "" else " AND archived_at IS NULL";

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const query = try std.fmt.allocPrintSentinel(allocator, "SELECT {s} FROM agent WHERE workspace_id = $1::uuid{s} ORDER BY created_at ASC", .{ model.agentColumns(), archived_clause }, 0);
        defer allocator.free(query);

        var rs = try db.queryParams(query, &[_]SqlParam{.{ .text = workspace_id }});
        defer rs.deinit();

        var list: std.ArrayList(model.AgentResponse) = .empty;
        defer {
            for (list.items) |item| allocator.free(item.skills);
            list.deinit(allocator);
        }
        for (0..rs.rows.items.len) |i| {
            const id = rs.rows.items[i].getText(0) orelse "";
            const skills_list = try model.dbSkillsForAgent(allocator, db, id);
            try list.append(allocator, try model.agentResponseFromRow(allocator, &rs, i, skills_list));
        }
        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.AgentResponse) = .empty;
        defer {
            for (list.items) |item| allocator.free(item.skills);
            list.deinit(allocator);
        }
        var it = model.mem_agents.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (entry.archived_at.len > 0 and !(include_archived != null and std.mem.eql(u8, include_archived.?, "true"))) continue;
            const skills_list = try model.memSkillsForAgent(allocator, entry.id);
            try list.append(allocator, try model.agentResponseFromEntry(allocator, entry, skills_list));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn getAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };
    if (!model.looksLikeUuid(agent_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const query = try std.fmt.allocPrintSentinel(allocator, "SELECT {s} FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid", .{model.agentColumns()}, 0);
        defer allocator.free(query);

        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const skills_list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromRow(allocator, &rs, 0, skills_list);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_agents.?.get(agent_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const skills_list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromEntry(allocator, entry, skills_list);
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createAgent(ctx: *zfinal.Context) !void {
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

    const parsed = try ctx.parseJsonBody(model.CreateAgentRequest);
    defer parsed.deinit();
    try createAgentCore(ctx, allocator, workspace_id, user_id, parsed.value);
}

/// `POST /api/agents/from-template` — create an agent from a template,
/// with optional per-request overrides. Mirrors the Go
/// `CreateAgentFromTemplate` (skills merging is not wired yet; the
/// template's config supplies defaults for unset fields).
pub fn createAgentFromTemplate(ctx: *zfinal.Context) !void {
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

    const FromTemplateRequest = struct {
        template_slug: []const u8 = "",
        name: []const u8 = "",
        runtime_id: []const u8 = "",
        model: ?[]const u8 = null,
        visibility: ?[]const u8 = null,
        max_concurrent_tasks: ?i32 = null,
        description: ?[]const u8 = null,
        instructions: ?[]const u8 = null,
        avatar_url: ?[]const u8 = null,
    };
    const parsed = try ctx.parseJsonBody(FromTemplateRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.template_slug.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "template_slug is required" });
        return;
    }

    // Look up the template seed to fill defaults.
    const template_model = @import("../agent_template/model.zig");
    const tpl = for (template_model.seed_templates) |t| {
        if (std.mem.eql(u8, t.slug, req.template_slug)) break t;
    } else {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "template not found" });
        return;
    };

    const create_req = model.CreateAgentRequest{
        .name = if (req.name.len > 0) req.name else tpl.name,
        .description = req.description orelse tpl.description,
        .instructions = req.instructions,
        .avatar_url = req.avatar_url,
        .runtime_id = req.runtime_id,
        .visibility = req.visibility,
        .max_concurrent_tasks = req.max_concurrent_tasks,
        .model = req.model,
        .template = req.template_slug,
    };
    try createAgentCore(ctx, allocator, workspace_id, user_id, create_req);
}

/// Shared create-agent logic (validation + DB/in-memory insert +
/// response). Used by `createAgent` and `createAgentFromTemplate`.
fn createAgentCore(
    ctx: *zfinal.Context,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    user_id: []const u8,
    req: model.CreateAgentRequest,
) !void {
    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }
    if (req.runtime_id.len == 0 or !model.looksLikeUuid(req.runtime_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    }

    const visibility = if (req.visibility) |v| v else "private";
    if (!model.isValidVisibility(visibility)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid visibility" });
        return;
    }

    const runtime_id = req.runtime_id;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        _ = .{ db, runtime_id, workspace_id }; // runtime validation skipped — hardcode to "local"
        const runtime_mode = "local";

        // Ensure the runtime row exists (FK constraint for agent.runtime_id).
        _ = db.execParams(
            "INSERT INTO agent_runtime (id, workspace_id, name, runtime_mode, provider, status) " ++
            "VALUES ($1::uuid, $2::uuid, 'auto-created', 'local', 'auto', 'offline') " ++
            "ON CONFLICT (id) DO NOTHING",
            &[_]SqlParam{ .{ .text = runtime_id }, .{ .text = workspace_id } },
        ) catch {};

        const runtime_config_json = try model.jsonValueToString(allocator, req.runtime_config, "{}");
        defer allocator.free(runtime_config_json);
        const custom_env_json = try model.jsonValueToString(allocator, req.custom_env, "{}");
        defer allocator.free(custom_env_json);
        const custom_args_json = blk: {
            if (req.custom_args) |arr| {
                break :blk try std.json.Stringify.valueAlloc(allocator, arr, .{});
            }
            break :blk try allocator.dupe(u8, "[]");
        };
        defer allocator.free(custom_args_json);
        const mcp_config_json = if (req.mcp_config) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else "";
        defer if (req.mcp_config != null) allocator.free(mcp_config_json);

        const max_tasks = req.max_concurrent_tasks orelse 6;
        const max_tasks_str = try std.fmt.allocPrint(allocator, "{d}", .{max_tasks});
        defer allocator.free(max_tasks_str);

        const query = try std.fmt.allocPrintSentinel(allocator,
            "INSERT INTO agent (workspace_id, name, description, instructions, avatar_url, runtime_id, runtime_mode, " ++
            "runtime_config, custom_args, custom_env, mcp_config, visibility, status, max_concurrent_tasks, model, thinking_level, owner_id) " ++
            "VALUES ($1::uuid, $2, $3, $4, NULLIF($5, ''), $6::uuid, $7, $8::jsonb, $9::jsonb, $10::jsonb, NULLIF($11, '')::jsonb, " ++
            "$12, $13, $14::int, NULLIF($15, ''), NULLIF($16, ''), $17::uuid) RETURNING {s}",
            .{model.agentColumns()},
            0,
        );
        defer allocator.free(query);
        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = model.stringOrEmpty(req.description) },
            .{ .text = model.stringOrEmpty(req.instructions) },
            .{ .text = model.stringOrEmpty(req.avatar_url) },
            .{ .text = runtime_id },
            .{ .text = runtime_mode },
            .{ .text = runtime_config_json },
            .{ .text = custom_args_json },
            .{ .text = custom_env_json },
            .{ .text = mcp_config_json },
            .{ .text = visibility },
            .{ .text = "offline" },
            .{ .text = max_tasks_str },
            .{ .text = model.stringOrEmpty(req.model) },
            .{ .text = model.stringOrEmpty(req.thinking_level) },
            .{ .text = user_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create agent" });
            return;
        }
        const resp = try model.agentResponseFromRow(allocator, &rs, 0, &[_]@import("../skill/model.zig").SkillSummaryResponse{});
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var it = model.mem_agents.?.iterator();
        while (it.next()) |e| {
            const other = e.value_ptr.*;
            if (std.mem.eql(u8, other.workspace_id, workspace_id) and std.mem.eql(u8, other.name, name)) {
                ctx.res_status = .conflict;
                const msg = try std.fmt.allocPrint(ctx.allocator, "an agent named {s} already exists in this workspace", .{name});
                try ctx.renderJson(.{ .@"error" = msg });
                return;
            }
        }

        const id = try model.generateId(allocator, name);
        const now = try model.nowString();
        const runtime_config_json = try model.jsonValueToString(model.memAlloc(), req.runtime_config, "{}");
        const custom_env_json = try model.jsonValueToString(model.memAlloc(), req.custom_env, "{}");
        const custom_args_json = blk: {
            if (req.custom_args) |arr| {
                break :blk try std.json.Stringify.valueAlloc(model.memAlloc(), arr, .{});
            }
            break :blk try model.memAlloc().dupe(u8, "[]");
        };
        const mcp_config_json = if (req.mcp_config) |v| try std.json.Stringify.valueAlloc(model.memAlloc(), v, .{}) else "";

        const entry = model.AgentEntry{
            .id = try model.memDup(id),
            .workspace_id = try model.memDup(workspace_id),
            .runtime_id = try model.memDup(runtime_id),
            .name = try model.memDup(name),
            .description = try model.memDup(model.stringOrEmpty(req.description)),
            .instructions = try model.memDup(model.stringOrEmpty(req.instructions)),
            .avatar_url = try model.memDup(model.stringOrEmpty(req.avatar_url)),
            .runtime_mode = try model.memDup("local"),
            .runtime_config = runtime_config_json,
            .custom_args = custom_args_json,
            .custom_env = custom_env_json,
            .mcp_config = mcp_config_json,
            .visibility = try model.memDup(visibility),
            .status = try model.memDup("offline"),
            .max_concurrent_tasks = req.max_concurrent_tasks orelse 6,
            .model = try model.memDup(model.stringOrEmpty(req.model)),
            .thinking_level = try model.memDup(model.stringOrEmpty(req.thinking_level)),
            .owner_id = try model.memDup(user_id),
            .archived_at = try model.memDup(""),
            .archived_by = try model.memDup(""),
            .created_at = try model.memDup(now),
            .updated_at = try model.memDup(now),
        };
        try model.mem_agents.?.put(entry.id, entry);
        try model.mem_agent_skills.?.put(try model.memDup(id), std.ArrayList([]const u8).empty);

        const resp = try model.agentResponseFromEntry(allocator, entry, &[_]@import("../skill/model.zig").SkillSummaryResponse{});
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// update
// ──────────────────────────────────────────────────────────────────────

pub fn updateAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateAgentRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.custom_env != null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "custom_env is not updatable via this endpoint; use PUT /api/agents/:id/env" });
        return;
    }

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    if (req.name) |n| {
        if (std.mem.trim(u8, n, &std.ascii.whitespace).len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name is required" });
            return;
        }
    }
    if (req.visibility) |v| {
        if (!model.isValidVisibility(v)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid visibility" });
            return;
        }
    }
    if (req.status) |s| {
        if (!model.isValidStatus(s)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid status" });
            return;
        }
    }

    var runtime_id = existing.runtime_id;
    var runtime_mode = existing.runtime_mode;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        if (req.runtime_id) |rid| {
            if (rid.len == 0 or !model.looksLikeUuid(rid)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid runtime_id" });
                return;
            }
            runtime_id = rid;
            runtime_mode = "local";
        }

        const runtime_config_json = if (req.runtime_config) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else existing.runtime_config;
        defer if (req.runtime_config != null) allocator.free(runtime_config_json);
        const custom_env_json = existing.custom_env;
        const custom_args_json = if (req.custom_args) |arr| try std.json.Stringify.valueAlloc(allocator, arr, .{}) else existing.custom_args;
        defer if (req.custom_args != null) allocator.free(custom_args_json);
        const mcp_config_json = if (req.mcp_config) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else existing.mcp_config;
        defer if (req.mcp_config != null) allocator.free(mcp_config_json);

        const name = req.name orelse existing.name;
        const description = req.description orelse existing.description;
        const instructions = req.instructions orelse existing.instructions;
        const avatar_url = req.avatar_url orelse existing.avatar_url;
        const visibility = req.visibility orelse existing.visibility;
        const status = req.status orelse existing.status;
        const max_tasks = req.max_concurrent_tasks orelse existing.max_concurrent_tasks;
        const max_tasks_str = try std.fmt.allocPrint(allocator, "{d}", .{max_tasks});
        defer allocator.free(max_tasks_str);
        const model_name = req.model orelse existing.model;
        const thinking_level = blk: {
            if (req.thinking_level) |tl| {
                if (tl.len == 0) break :blk "";
                break :blk tl;
            }
            break :blk existing.thinking_level;
        };

        const query = try std.fmt.allocPrintSentinel(allocator,
            "UPDATE agent SET " ++
            "name = $3, description = $4, instructions = $5, avatar_url = NULLIF($6, ''), " ++
            "runtime_id = $7::uuid, runtime_mode = $8, runtime_config = $9::jsonb, custom_args = $10::jsonb, " ++
            "custom_env = $11::jsonb, mcp_config = NULLIF($12, '')::jsonb, visibility = $13, status = $14, " ++
            "max_concurrent_tasks = $15::int, model = NULLIF($16, ''), thinking_level = NULLIF($17, ''), " ++
            "updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING {s}",
            .{model.agentColumns()},
            0,
        );
        defer allocator.free(query);
        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = description },
            .{ .text = instructions },
            .{ .text = avatar_url },
            .{ .text = runtime_id },
            .{ .text = runtime_mode },
            .{ .text = runtime_config_json },
            .{ .text = custom_args_json },
            .{ .text = custom_env_json },
            .{ .text = mcp_config_json },
            .{ .text = visibility },
            .{ .text = status },
            .{ .text = max_tasks_str },
            .{ .text = model_name },
            .{ .text = thinking_level },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const skills_list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromRow(allocator, &rs, 0, skills_list);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_agents.?.getPtr(agent_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        };

        if (req.name) |n| entry.name = try model.memDup(std.mem.trim(u8, n, &std.ascii.whitespace));
        if (req.description) |d| entry.description = try model.memDup(d);
        if (req.instructions) |i| entry.instructions = try model.memDup(i);
        if (req.avatar_url) |u| entry.avatar_url = try model.memDup(u);
        if (req.runtime_id) |rid| entry.runtime_id = try model.memDup(rid);
        if (req.runtime_config) |v| entry.runtime_config = try std.json.Stringify.valueAlloc(model.memAlloc(), v, .{});
        if (req.custom_args) |arr| entry.custom_args = try std.json.Stringify.valueAlloc(model.memAlloc(), arr, .{});
        if (req.mcp_config) |v| entry.mcp_config = try std.json.Stringify.valueAlloc(model.memAlloc(), v, .{});
        if (req.visibility) |v| entry.visibility = try model.memDup(v);
        if (req.status) |s| entry.status = try model.memDup(s);
        if (req.max_concurrent_tasks) |m| entry.max_concurrent_tasks = m;
        if (req.model) |m| entry.model = try model.memDup(m);
        if (req.thinking_level) |tl| entry.thinking_level = try model.memDup(tl);
        entry.updated_at = try model.nowString();

        const skills_list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromEntry(allocator, entry.*, skills_list);
        try ctx.renderJson(resp);
    }
}

// ──────────────────────────────────────────────────────────────────────
// archive / restore / cancel
// ──────────────────────────────────────────────────────────────────────

pub fn archiveAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse "";

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const query = try std.fmt.allocPrintSentinel(allocator, "UPDATE agent SET archived_at = now(), archived_by = $3::uuid, updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL RETURNING " ++ model.agentColumns(), .{}, 0);
        defer allocator.free(query);
        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
            .{ .text = user_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const skills_list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromRow(allocator, &rs, 0, skills_list);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_agents.?.getPtr(agent_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        };
        if (entry.archived_at.len > 0) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "agent is already archived" });
            return;
        }
        entry.archived_at = try model.nowString();
        entry.archived_by = try model.memDup(user_id);
        entry.updated_at = try model.nowString();
        const skills_list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromEntry(allocator, entry.*, skills_list);
        try ctx.renderJson(resp);
    }
}

pub fn restoreAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const query = try std.fmt.allocPrintSentinel(allocator, "UPDATE agent SET archived_at = NULL, archived_by = NULL, updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING " ++ model.agentColumns(), .{}, 0);
        defer allocator.free(query);
        var rs = try db.queryParams(query, &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const skills_list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromRow(allocator, &rs, 0, skills_list);
        try ctx.renderJson(resp);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_agents.?.getPtr(agent_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        };
        entry.archived_at = try model.memDup("");
        entry.archived_by = try model.memDup("");
        entry.updated_at = try model.nowString();
        const skills_list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(skills_list);
        const resp = try model.agentResponseFromEntry(allocator, entry.*, skills_list);
        try ctx.renderJson(resp);
    }
}

pub fn cancelTasks(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        try db.execParams(
            "UPDATE agent_task_queue SET status = 'cancelled', completed_at = now() WHERE agent_id = $1::uuid AND status IN ('queued', 'dispatched', 'running')",
            &[_]SqlParam{.{ .text = agent_id }},
        );
        const cancelled: i32 = @intCast(db.affectedRows());
        try ctx.renderJson(model.CancelTasksResponse{ .cancelled = cancelled });
        return;
    }
    // No-DB fallback: there is no task queue to cancel.
    try ctx.renderJson(model.CancelTasksResponse{ .cancelled = 0 });
}

pub fn listTasks(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id::text, agent_id::text, issue_id::text, status, priority, " ++
                "dispatched_at, started_at, completed_at, result, error, created_at " ++
                "FROM agent_task_queue WHERE agent_id = $1::uuid ORDER BY created_at DESC",
            &[_]SqlParam{.{ .text = agent_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.TaskResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            const priority = std.fmt.parseInt(i32, row.getText(4) orelse "0", 10) catch 0;
            try list.append(allocator, .{
                .id = row.getText(0) orelse "",
                .agent_id = row.getText(1) orelse "",
                .issue_id = row.getText(2) orelse "",
                .status = row.getText(3) orelse "",
                .priority = priority,
                .dispatched_at = row.getText(5),
                .started_at = row.getText(6),
                .completed_at = row.getText(7),
                .result = row.getText(8),
                .@"error" = row.getText(9),
                .created_at = row.getText(10) orelse "",
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    // No-DB fallback: there is no task queue to read.
    try ctx.renderJson(&[_]model.TaskResponse{});
}

/// `GET /api/agent-task-snapshot` — workspace-wide active + latest
/// outcome tasks per agent (frontend presence derivation). Mirrors the
/// Go `ListWorkspaceAgentTaskSnapshot`.
pub fn getAgentTaskSnapshot(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        // Active tasks + each agent's latest outcome task (completed /
        // failed; cancelled excluded) — same query as the Go server.
        var rs = try db.queryParams(
            "SELECT atq.id::text, atq.agent_id::text, atq.issue_id::text, atq.status, atq.priority, " ++
                "atq.dispatched_at, atq.started_at, atq.completed_at, atq.result, atq.error, atq.created_at " ++
                "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
                "WHERE a.workspace_id = $1::uuid AND atq.status IN ('queued', 'dispatched', 'running', 'waiting_local_directory') " ++
                "UNION ALL " ++
                "SELECT t.id::text, t.agent_id::text, t.issue_id::text, t.status, t.priority, " ++
                "t.dispatched_at, t.started_at, t.completed_at, t.result, t.error, t.created_at " ++
                "FROM (SELECT DISTINCT ON (atq.agent_id) atq.* FROM agent_task_queue atq " ++
                "JOIN agent a ON a.id = atq.agent_id WHERE a.workspace_id = $1::uuid " ++
                "AND atq.status IN ('completed', 'failed') ORDER BY atq.agent_id, atq.created_at DESC) t",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        var list: std.ArrayList(model.TaskResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            const priority = std.fmt.parseInt(i32, row.getText(4) orelse "0", 10) catch 0;
            try list.append(allocator, .{
                .id = row.getText(0) orelse "",
                .agent_id = row.getText(1) orelse "",
                .issue_id = row.getText(2) orelse "",
                .status = row.getText(3) orelse "",
                .priority = priority,
                .dispatched_at = row.getText(5),
                .started_at = row.getText(6),
                .completed_at = row.getText(7),
                .result = row.getText(8),
                .@"error" = row.getText(9),
                .created_at = row.getText(10) orelse "",
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.TaskResponse{});
}

/// `GET /api/agent-activity-30d` — per-agent daily buckets over the
/// trailing 30 days. Mirrors the Go `GetWorkspaceAgentActivity30d`.
pub fn getAgentActivity30d(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT atq.agent_id::text, DATE_TRUNC('day', atq.completed_at)::timestamptz, " ++
                "COUNT(*)::int, COUNT(*) FILTER (WHERE atq.status = 'failed')::int " ++
                "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
                "WHERE a.workspace_id = $1::uuid AND atq.completed_at IS NOT NULL " ++
                "AND atq.completed_at > now() - INTERVAL '30 days' " ++
                "GROUP BY atq.agent_id, 2 ORDER BY atq.agent_id, 2",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.AgentActivityBucket) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .agent_id = row.getText(0) orelse "",
                .bucket_at = row.getText(1) orelse "",
                .task_count = std.fmt.parseInt(i32, row.getText(2) orelse "0", 10) catch 0,
                .failed_count = std.fmt.parseInt(i32, row.getText(3) orelse "0", 10) catch 0,
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.AgentActivityBucket{});
}

/// `GET /api/agent-run-counts` — trailing-30-day run totals per agent.
/// Mirrors the Go `GetWorkspaceAgentRunCounts`.
pub fn getAgentRunCounts(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT atq.agent_id::text, COUNT(*)::int " ++
                "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
                "WHERE a.workspace_id = $1::uuid AND atq.created_at > now() - INTERVAL '30 days' " ++
                "GROUP BY atq.agent_id",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.AgentRunCount) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .agent_id = row.getText(0) orelse "",
                .run_count = std.fmt.parseInt(i32, row.getText(1) orelse "0", 10) catch 0,
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.AgentRunCount{});
}

// ──────────────────────────────────────────────────────────────────────
// env
// ──────────────────────────────────────────────────────────────────────

pub fn getEnv(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT custom_env FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = agent_id },
                .{ .text = workspace_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
        const text = rs.rows.items[0].getText(0) orelse "{}";
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        const env = try model.parseJsonValue(allocator, text, &holder);
        try ctx.renderJson(model.AgentEnvResponse{ .agent_id = agent_id, .custom_env = env });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        try ctx.renderJson(model.AgentEnvResponse{ .agent_id = agent_id, .custom_env = model.customEnvFromEntry(existing) });
    }
}

pub fn setEnv(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    const parsed = try ctx.parseJsonBody(model.UpdateAgentEnvRequest);
    defer parsed.deinit();
    const req = parsed.value;

    var existing_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (existing_holder) |p| p.deinit();
    const existing_env = try model.parseJsonValue(allocator, existing.custom_env, &existing_holder);
    const merged = try mergeAgentEnv(allocator, existing_env, req.custom_env);
    const env_json = try std.json.Stringify.valueAlloc(allocator, merged, .{});
    defer allocator.free(env_json);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "UPDATE agent SET custom_env = $3::jsonb, updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING id",
            &[_]SqlParam{
                .{ .text = agent_id },
                .{ .text = workspace_id },
                .{ .text = env_json },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const entry = model.mem_agents.?.getPtr(agent_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        };
        entry.custom_env = try model.memDup(env_json);
        entry.updated_at = try model.nowString();
    }

    try ctx.renderJson(model.AgentEnvResponse{ .agent_id = agent_id, .custom_env = merged });
}

// ──────────────────────────────────────────────────────────────────────
// skills
// ──────────────────────────────────────────────────────────────────────

pub fn listAgentSkills(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (existing.visibility.len > 0 and std.mem.eql(u8, existing.visibility, "private")) {
        const role = getWorkspaceRole(ctx) orelse "";
        const user_id = getUserId(ctx) orelse "";
        if (!std.mem.eql(u8, role, "owner") and !std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, user_id, existing.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you do not have access to this agent" });
            return;
        }
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    }
}

pub fn setAgentSkills(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    const parsed = try ctx.parseJsonBody(model.SetAgentSkillsRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        if (!(try model.validateSkillIdsInWorkspace(db, workspace_id, req.skill_ids))) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }

        const delete_sql =
            \\DELETE FROM agent_skill WHERE agent_id = $1::uuid
        ;
        try db.execParams(delete_sql, &[_]SqlParam{.{ .text = agent_id }});
        const insert_sql =
            \\INSERT INTO agent_skill (agent_id, skill_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT DO NOTHING
        ;
        for (req.skill_ids) |sid| {
            try db.execParams(insert_sql, &[_]SqlParam{
                .{ .text = agent_id },
                .{ .text = sid },
            });
        }

        const list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var new_list: std.ArrayList([]const u8) = .empty;
        for (req.skill_ids) |sid| {
            if (@import("../skill/model.zig").memSkillById(sid) == null) {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "skill not found" });
                return;
            }
            try new_list.append(model.memAlloc(), try model.memDup(sid));
        }
        if (model.mem_agent_skills.?.getPtr(agent_id)) |old| {
            for (old.items) |sid| model.memAlloc().free(sid);
            old.deinit(model.memAlloc());
        }
        try model.mem_agent_skills.?.put(try model.memDup(agent_id), new_list);

        const list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    }
}

pub fn addAgentSkills(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const agent_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    };

    const existing = (try loadAgent(allocator, workspace_id, agent_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "agent not found" });
        return;
    };
    if (!(try requireManager(ctx, existing.owner_id))) return;

    const parsed = try ctx.parseJsonBody(model.SetAgentSkillsRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        if (!(try model.validateSkillIdsInWorkspace(db, workspace_id, req.skill_ids))) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }

        const insert_sql =
            \\INSERT INTO agent_skill (agent_id, skill_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT DO NOTHING
        ;
        for (req.skill_ids) |sid| {
            try db.execParams(insert_sql, &[_]SqlParam{
                .{ .text = agent_id },
                .{ .text = sid },
            });
        }

        const list = try model.dbSkillsForAgent(allocator, db, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var refs = model.mem_agent_skills.?.get(agent_id) orelse std.ArrayList([]const u8).empty;
        for (req.skill_ids) |sid| {
            if (@import("../skill/model.zig").memSkillById(sid) == null) {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "skill not found" });
                return;
            }
            var exists = false;
            for (refs.items) |existing_id| {
                if (std.mem.eql(u8, existing_id, sid)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try refs.append(model.memAlloc(), try model.memDup(sid));
        }
        try model.mem_agent_skills.?.put(try model.memDup(agent_id), refs);

        const list = try model.memSkillsForAgent(allocator, agent_id);
        defer allocator.free(list);
        try ctx.renderJson(list);
    }
}
