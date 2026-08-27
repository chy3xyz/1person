//! Connector module — business logic.
//!
//! Owns the in-memory config + call-log stores and exposes
//! CRUD for configs, `call()` to simulate API calls, and
//! `listLogs()` for auditing. `handler.zig` is a thin delegate.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.connector_service);

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_configs: ?std.StringHashMap(model.ConnectorConfig) = null;
var mem_logs: ?std.ArrayList(model.ApiCallLog) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_configs == null) {
        mem_configs = std.StringHashMap(model.ConnectorConfig).init(memAlloc());
    }
    if (mem_logs == null) {
        mem_logs = std.ArrayList(model.ApiCallLog).empty;
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
        return common_mem.nowString();
    }

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

// ──────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────

const CreateConnectorRequest = struct {
    name: []const u8,
    base_url: []const u8,
    auth_type: []const u8 = "none",
    auth_value: []const u8 = "",
    timeout_ms: u32 = 30000,
    max_retries: u8 = 3,
};

const CallConnectorRequest = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    body: ?[]const u8 = null,
};

// ──────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────

pub fn createConfig(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(CreateConnectorRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }

    const base_url = std.mem.trim(u8, req.base_url, &std.ascii.whitespace);
    if (base_url.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "base_url is required" });
        return;
    }

    const auth_type = model.AuthType.fromString(req.auth_type) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid auth_type (use none, bearer, api_key, or basic)" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try model.generateId(allocator, name);
    const config = model.ConnectorConfig{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(name),
        .base_url = try memDup(base_url),
        .auth_type = auth_type,
        .auth_value = try memDup(req.auth_value),
        .timeout_ms = req.timeout_ms,
        .max_retries = req.max_retries,
    };
    try mem_configs.?.put(config.id, config);
    ctx.res_status = .created;
    try ctx.renderJson(model.configResponseFromConfig(config));
}

// ──────────────────────────────────────────────────────────────
// list
// ──────────────────────────────────────────────────────────────

pub fn listConfigs(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.ConnectorConfigResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_configs.?.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.*.workspace_id, workspace_id)) continue;
        try list.append(allocator, model.configResponseFromConfig(e.value_ptr.*));
    }
    try ctx.renderJson(.{ .connectors = list.items, .total = list.items.len });
}

// ──────────────────────────────────────────────────────────────
// get
// ──────────────────────────────────────────────────────────────

pub fn getConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const config_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "config_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const config = mem_configs.?.get(config_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    };
    if (!std.mem.eql(u8, config.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    }
    try ctx.renderJson(model.configResponseFromConfig(config));
}

// ──────────────────────────────────────────────────────────────
// update
// ──────────────────────────────────────────────────────────────

const UpdateConnectorRequest = struct {
    name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    auth_type: ?[]const u8 = null,
    auth_value: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    max_retries: ?u8 = null,
};

pub fn updateConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const config_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "config_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(UpdateConnectorRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.auth_type) |at| {
        if (model.AuthType.fromString(at) == null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid auth_type" });
            return;
        }
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_configs.?.getPtr(config_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    }

    if (req.name) |n| {
        const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.name = try memDup(trimmed);
    }
    if (req.base_url) |b| {
        const trimmed = std.mem.trim(u8, b, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.base_url = try memDup(trimmed);
    }
    if (req.auth_type) |at| {
        entry.auth_type = model.AuthType.fromString(at).?;
    }
    if (req.auth_value) |av| {
        entry.auth_value = try memDup(av);
    }
    if (req.timeout_ms) |t| entry.timeout_ms = t;
    if (req.max_retries) |r| entry.max_retries = r;

    try ctx.renderJson(model.configResponseFromConfig(entry.*));
}

// ──────────────────────────────────────────────────────────────
// delete
// ──────────────────────────────────────────────────────────────

pub fn deleteConfig(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const config_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "config_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_configs.?.fetchRemove(config_id)) |kv| {
        const config = kv.value;
        if (!std.mem.eql(u8, config.workspace_id, workspace_id)) {
            try mem_configs.?.put(config.id, config);
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "connector config not found" });
            return;
        }
    } else {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    }

    try response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────
// call — simulate an API call, return a mock response, log it
// ──────────────────────────────────────────────────────────────

pub fn call(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const config_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "config_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(CallConnectorRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const config = mem_configs.?.get(config_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    };
    if (!std.mem.eql(u8, config.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    }

    // Simulate a call duration between 10-200ms
    const seed: u64 = @intCast(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds());
    var prng = std.Random.DefaultPrng.init(seed);
    const duration_ms: u64 = 10 + prng.random().uintLessThan(u64, 191);

    // Always return mock success response
    const status_code: u16 = 200;

    const log_id = try model.generateId(ctx.allocator, config_id);
    const now = try nowString();
    const call_log = model.ApiCallLog{
        .id = try memDup(log_id),
        .config_id = try memDup(config_id),
        .method = try memDup(req.method),
        .path = try memDup(req.path),
        .status_code = status_code,
        .duration_ms = duration_ms,
        .created_at = try memDup(now),
    };
    try mem_logs.?.append(memAlloc(), call_log);

    // Return mock response
    try ctx.renderJson(.{
        .status = status_code,
        .duration_ms = duration_ms,
        .log_id = log_id,
        .mock_response = .{
            .ok = true,
            .message = "simulated call succeeded",
        },
    });
}

// ──────────────────────────────────────────────────────────────
// listLogs
// ──────────────────────────────────────────────────────────────

pub fn listLogs(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const config_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "config_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // Verify the config exists in this workspace
    const config = mem_configs.?.get(config_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    };
    if (!std.mem.eql(u8, config.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "connector config not found" });
        return;
    }

    var list: std.ArrayList(model.ApiCallLogResponse) = .empty;
    defer list.deinit(allocator);
    for (mem_logs.?.items) |l| {
        if (std.mem.eql(u8, l.config_id, config_id)) {
            try list.append(allocator, model.logResponseFromLog(l));
        }
    }
    try ctx.renderJson(.{ .logs = list.items, .total = list.items.len });
}
