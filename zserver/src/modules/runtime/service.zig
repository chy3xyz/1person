//! Runtime module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory
//! `mem_runtimes` map and the four async request stores:
//! `mem_updates`, `mem_models`, `mem_local_skills`,
//! `mem_local_imports`) and exposes the HTTP-facing operations:
//! `listAgentRuntimes`, `updateAgentRuntime`, `deleteAgentRuntime`,
//! `archiveAgentsAndDeleteRuntime`, `getRuntimeUsage`,
//! `getRuntimeUsageByAgent`, `getRuntimeUsageByHour`,
//! `getRuntimeTaskActivity`, `initiateUpdate`, `getUpdate`,
//! `initiateListModels`, `getModelListRequest`,
//! `initiateListLocalSkills`, `getLocalSkillListRequest`,
//! `initiateImportLocalSkill`, `getLocalSkillImportRequest`, plus
//! the `*Store*` accessors consumed by the daemon module. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const task_queue = @import("../../task_queue.zig");
const common_ctx = @import("../../common/ctx.zig");

// Re-export the model types used by the daemon service so consumers
// can keep importing from `../runtime/service.zig`.
pub const ModelEntry = model.ModelEntry;
pub const RuntimeLocalSkillSummary = model.RuntimeLocalSkillSummary;
pub const UpdateRequest = model.UpdateRequest;
pub const ModelListRequest = model.ModelListRequest;
pub const RuntimeLocalSkillListRequest = model.RuntimeLocalSkillListRequest;
pub const RuntimeLocalSkillImportRequest = model.RuntimeLocalSkillImportRequest;

const log = std.log.scoped(.runtime_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_runtimes: ?std.StringHashMap(model.RuntimeEntry) = null;

// Async request stores (update / models / local-skills / local-imports).
// Mirrors the Go backend's pending-request pattern: the frontend
// POSTs a request, gets a request_id, and polls GET until it
// reaches a terminal state. The daemon claims the request via
// heartbeat and reports the result. There is no backing Postgres
// table for the request envelope itself, so both the DB-enabled and
// no-DB paths use the same in-memory stores. When a DB is available
// we still validate runtime ownership against agent_runtime first.

const update_status_pending = "pending";
const update_status_running = "running";
const update_status_completed = "completed";
const update_status_failed = "failed";

const local_skill_status_pending = "pending";
const local_skill_status_running = "running";
const local_skill_status_completed = "completed";
const local_skill_status_failed = "failed";
const local_skill_status_conflict = "conflict";

var async_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_updates: ?std.StringHashMap(model.UpdateRequest) = null;
var mem_models: ?std.StringHashMap(model.ModelListRequest) = null;
var mem_local_skills: ?std.StringHashMap(model.RuntimeLocalSkillListRequest) = null;
var mem_local_imports: ?std.StringHashMap(model.RuntimeLocalSkillImportRequest) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return model.memAlloc();
}

fn memInit() !void {
    if (mem_runtimes == null) {
        mem_runtimes = std.StringHashMap(model.RuntimeEntry).init(memAlloc());
    }
}

fn asyncMemInit() !void {
    if (mem_updates == null) {
        mem_updates = std.StringHashMap(model.UpdateRequest).init(memAlloc());
        mem_models = std.StringHashMap(model.ModelListRequest).init(memAlloc());
        mem_local_skills = std.StringHashMap(model.RuntimeLocalSkillListRequest).init(memAlloc());
        mem_local_imports = std.StringHashMap(model.RuntimeLocalSkillImportRequest).init(memAlloc());
    }
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn parseInt64(text: ?[]const u8) i64 {
    return std.fmt.parseInt(i64, text orelse "0", 10) catch 0;
}

fn parseInt32(text: ?[]const u8) i32 {
    return std.fmt.parseInt(i32, text orelse "0", 10) catch 0;
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getUserId(ctx);
    }

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

fn nowString() ![]const u8 {
    return try model.nowString();
}

fn memDup(s: []const u8) ![]const u8 {
    return try model.memDup(s);
}

fn copyOptionalString(s: ?[]const u8) !?[]const u8 {
    if (s) |v| return try memDup(v);
    return null;
}

fn makeId() ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(memAlloc(), "req:{d}", .{ns});
    defer memAlloc().free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try memAlloc().alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn runtimeOnlineCheck(ctx: *zfinal.Context, status: []const u8) bool {
    if (!std.mem.eql(u8, status, "online")) {
        ctx.res_status = .service_unavailable;
        ctx.renderJson(.{ .@"error" = "runtime is offline" }) catch {};
        return false;
    }
    return true;
}

fn updateRequestTerminal(status: []const u8) bool {
    return std.mem.eql(u8, status, update_status_completed) or
        std.mem.eql(u8, status, update_status_failed);
}

fn modelRequestTerminal(status: []const u8) bool {
    return std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "timeout");
}

fn localSkillRequestTerminal(status: []const u8) bool {
    return std.mem.eql(u8, status, local_skill_status_completed) or
        std.mem.eql(u8, status, local_skill_status_failed) or
        std.mem.eql(u8, status, local_skill_status_conflict) or
        std.mem.eql(u8, status, "timeout");
}

// ──────────────────────────────────────────────────────────────────────
// runtime CRUD
// ──────────────────────────────────────────────────────────────────────

pub fn listAgentRuntimes(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        var rs = try d.queryParams(
            "SELECT * FROM agent_runtime WHERE workspace_id = $1::uuid ORDER BY created_at ASC",
            &[_]zfinal.SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();

        var list: std.ArrayList(model.AgentRuntimeResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, model.runtimeResponseFromRow(&rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.AgentRuntimeResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_runtimes.?.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.value_ptr.*.workspace_id, workspace_id)) continue;
            try list.append(allocator, model.runtimeResponseFromEntry(e.value_ptr.*));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn updateAgentRuntime(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthenticated" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateAgentRuntimeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = try model.resolveMemberRole(ctx, d, workspace_id, user_id);
        if (!model.canEditRuntime(role, user_id, rt.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only edit your own runtimes" });
            return;
        }

        var new_visibility: ?[]const u8 = null;
        if (req.visibility) |v| {
            if (!std.mem.eql(u8, v, "private") and !std.mem.eql(u8, v, "public")) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "visibility must be 'private' or 'public'" });
                return;
            }
            if (!std.mem.eql(u8, v, rt.visibility)) {
                new_visibility = v;
            }
        }

        if (new_visibility) |v| {
            var rs = try d.queryParams(
                "UPDATE agent_runtime SET visibility = $1, updated_at = now() WHERE id = $2::uuid RETURNING *",
                &[_]zfinal.SqlParam{ .{ .text = v }, .{ .text = runtime_id } },
            );
            defer rs.deinit();
            if (rs.rows.items.len == 0) {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "runtime not found" });
                return;
            }
            try ctx.renderJson(model.runtimeResponseFromRow(&rs, 0));
        } else {
            try ctx.renderJson(rt);
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const gop = try mem_runtimes.?.getOrPut(runtime_id);
        if (!gop.found_existing) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        if (!std.mem.eql(u8, gop.value_ptr.*.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        if (!model.canEditRuntime(null, user_id, gop.value_ptr.*.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only edit your own runtimes" });
            return;
        }
        if (req.visibility) |v| {
            if (!std.mem.eql(u8, v, "private") and !std.mem.eql(u8, v, "public")) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "visibility must be 'private' or 'public'" });
                return;
            }
            memAlloc().free(gop.value_ptr.*.visibility);
            gop.value_ptr.*.visibility = try memDup(v);
            memAlloc().free(gop.value_ptr.*.updated_at);
            gop.value_ptr.*.updated_at = try nowString();
        }
        try ctx.renderJson(model.runtimeResponseFromEntry(gop.value_ptr.*));
    }
}

pub fn deleteAgentRuntime(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthenticated" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = try model.resolveMemberRole(ctx, d, workspace_id, user_id);
        if (!model.canEditRuntime(role, user_id, rt.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only delete your own runtimes" });
            return;
        }

        var count_res = try d.queryParams(
            "SELECT count(*) FROM agent WHERE runtime_id = $1::uuid AND archived_at IS NULL",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );
        defer count_res.deinit();
        const active_count: i64 = @intCast(std.fmt.parseInt(i64, count_res.rows.items[0].getText(0) orelse "0", 10) catch 0);
        if (active_count > 0) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{
                .@"error" = "cannot delete runtime: it has active agents bound to it. Archive or reassign the agents first.",
                .@"code" = "runtime_has_active_agents",
            });
            return;
        }

        _ = try d.queryParams(
            "DELETE FROM agent WHERE runtime_id = $1::uuid AND archived_at IS NOT NULL",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );
        _ = try d.queryParams(
            "DELETE FROM agent_runtime WHERE id = $1::uuid",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );
        try ctx.renderJson(.{ .@"status" = "ok" });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        if (!model.canEditRuntime(null, user_id, entry.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only delete your own runtimes" });
            return;
        }
        _ = mem_runtimes.?.remove(runtime_id);
        _ = task_queue.cancelByRuntime(runtime_id) catch 0;
        try ctx.renderJson(.{ .@"status" = "ok" });
    }
}

pub fn archiveAgentsAndDeleteRuntime(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthenticated" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.ArchiveAgentsAndDeleteRuntimeRequest);
    defer parsed.deinit();

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = try model.resolveMemberRole(ctx, d, workspace_id, user_id);
        if (!model.canEditRuntime(role, user_id, rt.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only delete your own runtimes" });
            return;
        }

        // Simplified cascade: archive all active agents on this runtime,
        // cancel their active tasks, then delete the runtime.
        var archived_res = try d.queryParams(
            "UPDATE agent SET archived_at = now(), archived_by = $1::uuid, updated_at = now() " ++
                "WHERE runtime_id = $2::uuid AND archived_at IS NULL RETURNING id",
            &[_]zfinal.SqlParam{ .{ .text = user_id }, .{ .text = runtime_id } },
        );
        defer archived_res.deinit();
        const archived_count = archived_res.rows.items.len;

        var cancelled_res = try d.queryParams(
            "UPDATE agent_task_queue SET status = 'cancelled', completed_at = now() " ++
                "WHERE runtime_id = $1::uuid AND status IN ('queued','dispatched','running','waiting_local_directory') " ++
                "RETURNING id",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );
        defer cancelled_res.deinit();
        const cancelled_count = cancelled_res.rows.items.len;

        _ = try d.queryParams(
            "DELETE FROM agent WHERE runtime_id = $1::uuid AND archived_at IS NOT NULL",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );
        _ = try d.queryParams(
            "DELETE FROM agent_runtime WHERE id = $1::uuid",
            &[_]zfinal.SqlParam{.{ .text = runtime_id }},
        );

        try ctx.renderJson(.{
            .@"status" = "ok",
            .agents_archived = archived_count,
            .tasks_cancelled = cancelled_count,
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        if (!model.canEditRuntime(null, user_id, entry.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "you can only delete your own runtimes" });
            return;
        }
        _ = mem_runtimes.?.remove(runtime_id);
        const cancelled = task_queue.cancelByRuntime(runtime_id) catch 0;
        try ctx.renderJson(.{
            .@"status" = "ok",
            .agents_archived = @as(usize, 0),
            .tasks_cancelled = cancelled,
        });
    }
}

// ──────────────────────────────────────────────────────────────────────
// usage / activity
// ──────────────────────────────────────────────────────────────────────

/// Shared header validation for the usage endpoints: returns
/// `workspace_id` + `runtime_id` (both required), or writes a 400 and
/// returns `null`.
fn usageParams(ctx: *zfinal.Context) ?struct { workspace_id: []const u8, runtime_id: []const u8 } {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        ctx.renderJson(.{ .@"error" = "workspace_id is required" }) catch {};
        return null;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        ctx.renderJson(.{ .@"error" = "runtime_id is required" }) catch {};
        return null;
    };
    return .{ .workspace_id = workspace_id, .runtime_id = runtime_id };
}

pub fn getRuntimeUsage(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const p = usageParams(ctx) orelse return;

    if (deps.hasPool()) {
        const db = deps.acquire() catch {
            try ctx.renderJson(&[_]model.RuntimeUsageResponse{});
            return;
        };
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT DATE(bucket_hour AT TIME ZONE 'UTC'), provider, model, " ++
                "SUM(input_tokens)::bigint, SUM(output_tokens)::bigint, " ++
                "SUM(cache_read_tokens)::bigint, SUM(cache_write_tokens)::bigint " ++
                "FROM task_usage_hourly WHERE runtime_id = $1::uuid " ++
                "AND bucket_hour >= now() - interval '90 days' " ++
                "GROUP BY 1, 2, 3 ORDER BY 1 DESC, 2, 3",
            &[_]SqlParam{.{ .text = p.runtime_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.RuntimeUsageResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .runtime_id = p.runtime_id,
                .date = row.getText(0) orelse "",
                .provider = row.getText(1) orelse "",
                .model = row.getText(2) orelse "",
                .input_tokens = parseInt64(row.getText(3)),
                .output_tokens = parseInt64(row.getText(4)),
                .cache_read_tokens = parseInt64(row.getText(5)),
                .cache_write_tokens = parseInt64(row.getText(6)),
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.RuntimeUsageResponse{});
}

pub fn getRuntimeUsageByAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const p = usageParams(ctx) orelse return;

    if (deps.hasPool()) {
        const db = deps.acquire() catch {
            try ctx.renderJson(&[_]model.RuntimeUsageByAgentResponse{});
            return;
        };
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT atq.agent_id::text, tu.model, " ++
                "SUM(tu.input_tokens)::bigint, SUM(tu.output_tokens)::bigint, " ++
                "SUM(tu.cache_read_tokens)::bigint, SUM(tu.cache_write_tokens)::bigint, " ++
                "COUNT(DISTINCT tu.task_id)::int " ++
                "FROM task_usage tu JOIN agent_task_queue atq ON atq.id = tu.task_id " ++
                "WHERE atq.runtime_id = $1::uuid AND tu.created_at >= now() - interval '90 days' " ++
                "GROUP BY atq.agent_id, tu.model ORDER BY atq.agent_id, tu.model",
            &[_]SqlParam{.{ .text = p.runtime_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.RuntimeUsageByAgentResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .agent_id = row.getText(0) orelse "",
                .model = row.getText(1) orelse "",
                .input_tokens = parseInt64(row.getText(2)),
                .output_tokens = parseInt64(row.getText(3)),
                .cache_read_tokens = parseInt64(row.getText(4)),
                .cache_write_tokens = parseInt64(row.getText(5)),
                .task_count = parseInt32(row.getText(6)),
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.RuntimeUsageByAgentResponse{});
}

pub fn getRuntimeUsageByHour(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const p = usageParams(ctx) orelse return;

    if (deps.hasPool()) {
        const db = deps.acquire() catch {
            try ctx.renderJson(&[_]model.RuntimeUsageByHourResponse{});
            return;
        };
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT EXTRACT(HOUR FROM tu.created_at AT TIME ZONE 'UTC')::int, tu.model, " ++
                "SUM(tu.input_tokens)::bigint, SUM(tu.output_tokens)::bigint, " ++
                "SUM(tu.cache_read_tokens)::bigint, SUM(tu.cache_write_tokens)::bigint, " ++
                "COUNT(DISTINCT tu.task_id)::int " ++
                "FROM task_usage tu JOIN agent_task_queue atq ON atq.id = tu.task_id " ++
                "WHERE atq.runtime_id = $1::uuid AND tu.created_at >= now() - interval '90 days' " ++
                "GROUP BY 1, tu.model ORDER BY 1, tu.model",
            &[_]SqlParam{.{ .text = p.runtime_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.RuntimeUsageByHourResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .hour = parseInt32(row.getText(0)),
                .model = row.getText(1) orelse "",
                .input_tokens = parseInt64(row.getText(2)),
                .output_tokens = parseInt64(row.getText(3)),
                .cache_read_tokens = parseInt64(row.getText(4)),
                .cache_write_tokens = parseInt64(row.getText(5)),
                .task_count = parseInt32(row.getText(6)),
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.RuntimeUsageByHourResponse{});
}

pub fn getRuntimeTaskActivity(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const p = usageParams(ctx) orelse return;

    if (deps.hasPool()) {
        const db = deps.acquire() catch {
            try ctx.renderJson(&[_]model.HourlyActivity{});
            return;
        };
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT EXTRACT(HOUR FROM started_at AT TIME ZONE 'UTC')::int, COUNT(*)::int " ++
                "FROM agent_task_queue WHERE runtime_id = $1::uuid AND started_at IS NOT NULL " ++
                "GROUP BY 1 ORDER BY 1",
            &[_]SqlParam{.{ .text = p.runtime_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.HourlyActivity) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            try list.append(allocator, .{
                .hour = parseInt32(row.getText(0)),
                .count = parseInt32(row.getText(1)),
            });
        }
        try ctx.renderJson(list.items);
        return;
    }
    try ctx.renderJson(&[_]model.HourlyActivity{});
}

// ──────────────────────────────────────────────────────────────────────
// Update store
// ──────────────────────────────────────────────────────────────────────

pub fn updateStoreGet(id: []const u8) ?model.UpdateRequest {
    if (mem_updates == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    return mem_updates.?.get(id);
}

pub fn updateStoreComplete(id: []const u8, output: []const u8) void {
    if (mem_updates == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_updates.?.getPtr(id) orelse return;
    req.status = update_status_completed;
    req.output = memDup(output) catch req.output;
    req.updated_at = nowString() catch req.updated_at;
}

pub fn updateStoreFail(id: []const u8, err_msg: []const u8) void {
    if (mem_updates == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_updates.?.getPtr(id) orelse return;
    req.status = update_status_failed;
    req.@"error" = memDup(err_msg) catch req.@"error";
    req.updated_at = nowString() catch req.updated_at;
}

pub fn updateStoreHasPending(runtime_id: []const u8) bool {
    if (mem_updates == null) return false;
    async_mutex.lock(zfinal.io_instance.io) catch return false;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_updates.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, update_status_pending)) return true;
    }
    return false;
}

pub fn updateStorePopPending(runtime_id: []const u8) ?model.UpdateRequest {
    if (mem_updates == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_updates.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, update_status_pending)) {
            e.value_ptr.*.status = update_status_running;
            e.value_ptr.*.updated_at = nowString() catch e.value_ptr.*.updated_at;
            return e.value_ptr.*;
        }
    }
    return null;
}

fn createUpdateRequest(runtime_id: []const u8, target_version: []const u8) !model.UpdateRequest {
    try asyncMemInit();
    try async_mutex.lock(zfinal.io_instance.io);
    defer async_mutex.unlock(zfinal.io_instance.io);

    var it = mem_updates.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            (std.mem.eql(u8, e.value_ptr.*.status, update_status_pending) or
                std.mem.eql(u8, e.value_ptr.*.status, update_status_running))) {
            return error.UpdateInProgress;
        }
    }

    const id = try makeId();
    const now = try nowString();
    const req = model.UpdateRequest{
        .id = id,
        .runtime_id = try memDup(runtime_id),
        .status = update_status_pending,
        .target_version = try memDup(target_version),
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_updates.?.put(id, req);
    return req;
}

// ──────────────────────────────────────────────────────────────────────
// Model list store
// ──────────────────────────────────────────────────────────────────────

pub fn modelStoreGet(id: []const u8) ?model.ModelListRequest {
    if (mem_models == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    return mem_models.?.get(id);
}

pub fn modelStoreComplete(id: []const u8, models: []const model.ModelEntry, supported: bool) void {
    if (mem_models == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_models.?.getPtr(id) orelse return;
    req.status = "completed";
    req.models = dupeModelEntries(models) catch req.models;
    req.supported = supported;
    req.updated_at = nowString() catch req.updated_at;
}

pub fn modelStoreFail(id: []const u8, err_msg: []const u8) void {
    if (mem_models == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_models.?.getPtr(id) orelse return;
    req.status = "failed";
    req.@"error" = memDup(err_msg) catch req.@"error";
    req.updated_at = nowString() catch req.updated_at;
}

pub fn modelStoreHasPending(runtime_id: []const u8) bool {
    if (mem_models == null) return false;
    async_mutex.lock(zfinal.io_instance.io) catch return false;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_models.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, "pending")) return true;
    }
    return false;
}

pub fn modelStorePopPending(runtime_id: []const u8) ?model.ModelListRequest {
    if (mem_models == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_models.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, "pending")) {
            e.value_ptr.*.status = "running";
            e.value_ptr.*.updated_at = nowString() catch e.value_ptr.*.updated_at;
            return e.value_ptr.*;
        }
    }
    return null;
}

fn dupeModelEntries(models: []const model.ModelEntry) ![]const model.ModelEntry {
    const slice = try memAlloc().alloc(model.ModelEntry, models.len);
    for (models, 0..) |m, i| {
        slice[i] = model.ModelEntry{
            .id = try memDup(m.id),
            .label = try memDup(m.label),
            .provider = try copyOptionalString(m.provider),
            .default = m.default,
            .thinking = m.thinking,
        };
    }
    return slice;
}

fn createModelListRequest(runtime_id: []const u8) !model.ModelListRequest {
    try asyncMemInit();
    try async_mutex.lock(zfinal.io_instance.io);
    defer async_mutex.unlock(zfinal.io_instance.io);
    const id = try makeId();
    const now = try nowString();
    const req = model.ModelListRequest{
        .id = id,
        .runtime_id = try memDup(runtime_id),
        .status = "pending",
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_models.?.put(id, req);
    return req;
}

// ──────────────────────────────────────────────────────────────────────
// Local skill list store
// ──────────────────────────────────────────────────────────────────────

pub fn localSkillStoreGet(id: []const u8) ?model.RuntimeLocalSkillListRequest {
    if (mem_local_skills == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    return mem_local_skills.?.get(id);
}

pub fn localSkillStoreComplete(id: []const u8, skills: []const model.RuntimeLocalSkillSummary, supported: bool) void {
    if (mem_local_skills == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_local_skills.?.getPtr(id) orelse return;
    req.status = local_skill_status_completed;
    req.skills = dupeSkillSummaries(skills) catch req.skills;
    req.supported = supported;
    req.updated_at = nowString() catch req.updated_at;
}

pub fn localSkillStoreFail(id: []const u8, err_msg: []const u8) void {
    if (mem_local_skills == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_local_skills.?.getPtr(id) orelse return;
    req.status = local_skill_status_failed;
    req.@"error" = memDup(err_msg) catch req.@"error";
    req.updated_at = nowString() catch req.updated_at;
}

pub fn localSkillStoreHasPending(runtime_id: []const u8) bool {
    if (mem_local_skills == null) return false;
    async_mutex.lock(zfinal.io_instance.io) catch return false;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_local_skills.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, local_skill_status_pending)) return true;
    }
    return false;
}

pub fn localSkillStorePopPending(runtime_id: []const u8) ?model.RuntimeLocalSkillListRequest {
    if (mem_local_skills == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_local_skills.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, local_skill_status_pending)) {
            e.value_ptr.*.status = local_skill_status_running;
            e.value_ptr.*.updated_at = nowString() catch e.value_ptr.*.updated_at;
            return e.value_ptr.*;
        }
    }
    return null;
}

fn dupeSkillSummaries(skills: []const model.RuntimeLocalSkillSummary) ![]const model.RuntimeLocalSkillSummary {
    const slice = try memAlloc().alloc(model.RuntimeLocalSkillSummary, skills.len);
    for (skills, 0..) |s, i| {
        slice[i] = model.RuntimeLocalSkillSummary{
            .key = try memDup(s.key),
            .name = try memDup(s.name),
            .description = try copyOptionalString(s.description),
            .source_path = try memDup(s.source_path),
            .provider = try memDup(s.provider),
            .file_count = s.file_count,
        };
    }
    return slice;
}

fn createLocalSkillListRequest(runtime_id: []const u8) !model.RuntimeLocalSkillListRequest {
    try asyncMemInit();
    try async_mutex.lock(zfinal.io_instance.io);
    defer async_mutex.unlock(zfinal.io_instance.io);
    const id = try makeId();
    const now = try nowString();
    const req = model.RuntimeLocalSkillListRequest{
        .id = id,
        .runtime_id = try memDup(runtime_id),
        .status = local_skill_status_pending,
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_local_skills.?.put(id, req);
    return req;
}

// ──────────────────────────────────────────────────────────────────────
// Local skill import store
// ──────────────────────────────────────────────────────────────────────

pub fn localImportStoreGet(id: []const u8) ?model.RuntimeLocalSkillImportRequest {
    if (mem_local_imports == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    return mem_local_imports.?.get(id);
}

pub fn localImportStoreComplete(id: []const u8, skill: std.json.Value) void {
    if (mem_local_imports == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_local_imports.?.getPtr(id) orelse return;
    req.status = local_skill_status_completed;
    req.skill = skill;
    req.updated_at = nowString() catch req.updated_at;
}

pub fn localImportStoreFail(id: []const u8, err_msg: []const u8) void {
    if (mem_local_imports == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_local_imports.?.getPtr(id) orelse return;
    req.status = local_skill_status_failed;
    req.@"error" = memDup(err_msg) catch req.@"error";
    req.updated_at = nowString() catch req.updated_at;
}

pub fn localImportStoreConflict(id: []const u8, info: model.LocalSkillImportConflict) void {
    if (mem_local_imports == null) return;
    async_mutex.lock(zfinal.io_instance.io) catch return;
    defer async_mutex.unlock(zfinal.io_instance.io);
    const req = mem_local_imports.?.getPtr(id) orelse return;
    req.status = local_skill_status_conflict;
    req.conflict = model.LocalSkillImportConflict{
        .existing_skill_id = memDup(info.existing_skill_id) catch req.conflict.?.existing_skill_id,
        .existing_created_by = copyOptionalString(info.existing_created_by) catch req.conflict.?.existing_created_by,
        .can_overwrite = info.can_overwrite,
    };
    req.updated_at = nowString() catch req.updated_at;
}

pub fn localImportStoreHasPending(runtime_id: []const u8) bool {
    if (mem_local_imports == null) return false;
    async_mutex.lock(zfinal.io_instance.io) catch return false;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_local_imports.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, local_skill_status_pending)) return true;
    }
    return false;
}

pub fn localImportStorePopPending(runtime_id: []const u8) ?model.RuntimeLocalSkillImportRequest {
    if (mem_local_imports == null) return null;
    async_mutex.lock(zfinal.io_instance.io) catch return null;
    defer async_mutex.unlock(zfinal.io_instance.io);
    var it = mem_local_imports.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, local_skill_status_pending)) {
            e.value_ptr.*.status = local_skill_status_running;
            e.value_ptr.*.updated_at = nowString() catch e.value_ptr.*.updated_at;
            return e.value_ptr.*;
        }
    }
    return null;
}

pub fn localImportStorePopPendingBatch(allocator: std.mem.Allocator, runtime_id: []const u8, limit: usize) ![]model.RuntimeLocalSkillImportRequest {
    if (mem_local_imports == null) return try allocator.alloc(model.RuntimeLocalSkillImportRequest, 0);
    async_mutex.lock(zfinal.io_instance.io) catch return try allocator.alloc(model.RuntimeLocalSkillImportRequest, 0);
    defer async_mutex.unlock(zfinal.io_instance.io);

    var pending: std.ArrayList(*model.RuntimeLocalSkillImportRequest) = .empty;
    defer pending.deinit(memAlloc());
    var it = mem_local_imports.?.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*.runtime_id, runtime_id) and
            std.mem.eql(u8, e.value_ptr.*.status, local_skill_status_pending)) {
            try pending.append(memAlloc(), e.value_ptr);
        }
    }

    const n = @min(pending.items.len, limit);
    const result = try allocator.alloc(model.RuntimeLocalSkillImportRequest, n);
    for (0..n) |i| {
        pending.items[i].status = local_skill_status_running;
        pending.items[i].updated_at = nowString() catch pending.items[i].updated_at;
        result[i] = pending.items[i].*;
    }
    return result;
}

fn createLocalSkillImportRequest(
    runtime_id: []const u8,
    creator_id: []const u8,
    skill_key: []const u8,
    name: ?[]const u8,
    description: ?[]const u8,
    action: ?[]const u8,
    target_skill_id: ?[]const u8,
    supports_conflict: bool,
) !model.RuntimeLocalSkillImportRequest {
    try asyncMemInit();
    try async_mutex.lock(zfinal.io_instance.io);
    defer async_mutex.unlock(zfinal.io_instance.io);
    const id = try makeId();
    const now = try nowString();
    const req = model.RuntimeLocalSkillImportRequest{
        .id = id,
        .runtime_id = try memDup(runtime_id),
        .skill_key = try memDup(skill_key),
        .name = try copyOptionalString(name),
        .description = try copyOptionalString(description),
        .action = try copyOptionalString(action),
        .target_skill_id = try copyOptionalString(target_skill_id),
        .supports_conflict = supports_conflict,
        .status = local_skill_status_pending,
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
        .creator_id = try memDup(creator_id),
    };
    try mem_local_imports.?.put(id, req);
    return req;
}

// ──────────────────────────────────────────────────────────────────────
// Runtime-facing handlers
// ──────────────────────────────────────────────────────────────────────

pub fn initiateUpdate(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.InitiateUpdateRequest);
    defer parsed.deinit();
    const req = parsed.value;
    if (std.mem.trim(u8, req.target_version, &std.ascii.whitespace).len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "target_version is required" });
        return;
    }

    var status: []const u8 = "online";
    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        status = rt.status;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        status = entry.status;
    }
    if (!runtimeOnlineCheck(ctx, status)) return;

    const update = try createUpdateRequest(runtime_id, req.target_version);
    // Payload carries the update_id so the daemon can report the result
    // against POST /runtimes/{rid}/update/{update_id}/result.
    _ = try task_queue.enqueue(runtime_id, .update, update.id);
    try ctx.renderJson(update);
}

pub fn getUpdate(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const update_id = ctx.getPathParam("updateId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "update_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
    }

    const update = updateStoreGet(update_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "update not found" });
        return;
    };
    if (!std.mem.eql(u8, update.runtime_id, runtime_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "update not found" });
        return;
    }
    try ctx.renderJson(update);
}

pub fn initiateListModels(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    var status: []const u8 = "online";
    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        status = rt.status;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        status = entry.status;
    }
    if (!runtimeOnlineCheck(ctx, status)) return;

    const model_req = try createModelListRequest(runtime_id);
    // Payload carries the request_id so the daemon can report the result
    // against POST /runtimes/{rid}/models/{request_id}/result.
    _ = try task_queue.enqueue(runtime_id, .models, model_req.id);
    try ctx.renderJson(model_req);
}

pub fn getModelListRequest(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
    }

    const model_req = modelStoreGet(request_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    };
    if (!std.mem.eql(u8, model_req.runtime_id, runtime_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    }
    try ctx.renderJson(model_req);
}

pub fn initiateListLocalSkills(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse "";
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    var status: []const u8 = "online";
    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = try model.resolveMemberRole(ctx, d, workspace_id, user_id);
        if (!model.canEditRuntime(role, user_id, rt.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        status = rt.status;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = getWorkspaceRole(ctx) orelse "";
        if (!model.canEditRuntime(role, user_id, entry.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        status = entry.status;
    }
    if (!runtimeOnlineCheck(ctx, status)) return;

    const skill_req = try createLocalSkillListRequest(runtime_id);
    // Payload carries the request_id so the daemon can report the result.
    _ = try task_queue.enqueue(runtime_id, .local_skills, skill_req.id);
    try ctx.renderJson(skill_req);
}

pub fn getLocalSkillListRequest(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
    }

    const skill_req = localSkillStoreGet(request_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    };
    if (!std.mem.eql(u8, skill_req.runtime_id, runtime_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    }
    try ctx.renderJson(skill_req);
}

pub fn initiateImportLocalSkill(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthenticated" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateRuntimeLocalSkillImportRequest);
    defer parsed.deinit();
    const req = parsed.value;
    const skill_key = std.mem.trim(u8, req.skill_key, &std.ascii.whitespace);
    if (skill_key.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_key is required" });
        return;
    }

    var status: []const u8 = "online";
    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = try model.resolveMemberRole(ctx, d, workspace_id, user_id);
        if (!model.canEditRuntime(role, user_id, rt.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        status = rt.status;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_runtimes.?.get(runtime_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
        const role = getWorkspaceRole(ctx) orelse "";
        if (!model.canEditRuntime(role, user_id, entry.owner_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
            return;
        }
        status = entry.status;
    }
    if (!runtimeOnlineCheck(ctx, status)) return;

    const import_req = try createLocalSkillImportRequest(
        runtime_id,
        user_id,
        skill_key,
        req.name,
        req.description,
        req.action,
        req.target_skill_id,
        req.supports_conflict,
    );
    // Payload carries the request_id so the daemon can report the result.
    _ = try task_queue.enqueue(runtime_id, .local_skill_import, import_req.id);
    try ctx.renderJson(import_req);
}

pub fn getLocalSkillImportRequest(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const rt = (try model.requireRuntimeAccess(ctx, d, runtime_id)) orelse return;
        if (!std.mem.eql(u8, rt.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "runtime not found" });
            return;
        }
    }

    const import_req = localImportStoreGet(request_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    };
    if (!std.mem.eql(u8, import_req.runtime_id, runtime_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "request not found" });
        return;
    }
    try ctx.renderJson(import_req);
}
