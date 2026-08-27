//! Pipeline service — in-memory CRUD for pipeline configs and runs.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

pub const PipelineConfig = model.PipelineConfig;
pub const PipelineRun = model.PipelineRun;
pub const PhaseRun = model.PhaseRun;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_configs: ?std.StringHashMap(model.PipelineConfig) = null;
var mem_runs: ?std.StringHashMap(model.PipelineRun) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }
fn memDup(text: []const u8) ![]const u8 {
        return common_mem.memDup(text);
    }

fn memInit() !void {
    if (mem_configs == null) {
        mem_configs = std.StringHashMap(model.PipelineConfig).init(memAlloc());
        mem_runs = std.StringHashMap(model.PipelineRun).init(memAlloc());
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
        return common_mem.generateId(prefix);
    }

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

fn nowMs() []const u8 {
    return std.fmt.allocPrint(memAlloc(), "{d}", .{std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds()}) catch "0";
}

/// ── Config CRUD ─────────────────────────────────────────

pub fn listPipelineConfigs(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list: std.ArrayList(model.PipelineConfig) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_configs) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .pipelines = list.items, .total = list.items.len });
}

pub fn createPipelineConfig(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreatePipelineRequest);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.name.len == 0) { try response.err(ctx, .bad_request, "name is required", 40021); return; }
    if (req.phases.len == 0) { try response.err(ctx, .bad_request, "at least one phase is required", 40022); return; }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const id = try generateId("pipe");
    const entry = model.PipelineConfig{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .description = try memDup(req.description),
        .phase_count = req.phases.len,
        .created_at = try memDup(nowMs()),
        .updated_at = try memDup(nowMs()),
    };
    try mem_configs.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn getPipelineConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse { try response.err(ctx, .bad_request, "pipeline_id is required", 40021); return; };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_configs.?.get(id) orelse { try response.err(ctx, .not_found, "pipeline not found", 40401); return; };
    try ctx.renderJson(entry);
}

pub fn updatePipelineConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse { try response.err(ctx, .bad_request, "pipeline_id is required", 40021); return; };
    const parsed = try ctx.parseJsonBody(model.UpdatePipelineRequest);
    defer parsed.deinit();
    const req = parsed.value;
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_configs.?.getPtr(id) orelse { try response.err(ctx, .not_found, "pipeline not found", 40401); return; };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    if (req.description) |d| entry_ptr.description = try memDup(d);
    if (req.phases) |p| entry_ptr.phase_count = p.len;
    entry_ptr.updated_at = try memDup(nowMs());
    try ctx.renderJson(entry_ptr.*);
}

pub fn deletePipelineConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse { try response.err(ctx, .bad_request, "pipeline_id is required", 40021); return; };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_configs.?.fetchRemove(id) orelse { try response.err(ctx, .not_found, "pipeline not found", 40401); return; };
    try response.okNoContent(ctx);
}

/// ── Run management ──────────────────────────────────────

pub fn startPipeline(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const pipeline_id = ctx.getPathParam("id") orelse { try response.err(ctx, .bad_request, "pipeline_id is required", 40021); return; };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_configs.?.get(pipeline_id) orelse { try response.err(ctx, .not_found, "pipeline not found", 40401); return; };
    const run_id = try generateId("run");
    const run = model.PipelineRun{
        .id = try memDup(run_id),
        .pipeline_id = try memDup(pipeline_id),
        .workspace_id = try memDup(workspace_id),
        .status = try memDup("running"),
        .current_phase_id = try memDup(""),
        .phases = .empty,
        .created_at = try memDup(nowMs()),
        .updated_at = try memDup(nowMs()),
    };
    try mem_runs.?.put(run.id, run);
    ctx.res_status = .created;
    try ctx.renderJson(run);
}

pub fn listPipelineRuns(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list: std.ArrayList(model.PipelineRun) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_runs) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .runs = list.items, .total = list.items.len });
}

pub fn getPipelineRun(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const run_id = ctx.getPathParam("runId") orelse { try response.err(ctx, .bad_request, "run_id is required", 40021); return; };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const run = mem_runs.?.get(run_id) orelse { try response.err(ctx, .not_found, "pipeline run not found", 40401); return; };
    try ctx.renderJson(run);
}

pub fn completePhase(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const run_id = ctx.getPathParam("runId") orelse { try response.err(ctx, .bad_request, "run_id is required", 40021); return; };
    _ = ctx.getPathParam("phaseId") orelse { try response.err(ctx, .bad_request, "phase_id is required", 40021); return; };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const run_ptr = mem_runs.?.getPtr(run_id) orelse { try response.err(ctx, .not_found, "pipeline run not found", 40401); return; };
    run_ptr.status = try memDup("done");
    run_ptr.updated_at = try memDup(nowMs());
    try ctx.renderJson(run_ptr.*);
}
