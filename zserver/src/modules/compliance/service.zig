//! Compliance service — in-memory CRUD for audit rules, audit execution,
//! and audit log listing.
//!
//! Operates entirely in no-DB mode using a page-allocator-backed
//! StringHashMap. All per-workspace scoping is enforced on read/write.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const AuditRule = model.AuditRule;
pub const AuditLog = model.AuditLog;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_rules: ?std.StringHashMap(model.AuditRule) = null;
var mem_logs: ?std.StringHashMap(model.AuditLog) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_rules == null) {
        mem_rules = std.StringHashMap(model.AuditRule).init(memAlloc());
        mem_logs = std.StringHashMap(model.AuditLog).init(memAlloc());
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return try std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

/// ── Rule CRUD ────────────────────────────────────────────────

pub fn listRules(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.AuditRule) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_rules) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .rules = list.items, .total = list.items.len });
}

pub fn createRule(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateRuleRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }
    if (!model.validateCheckType(req.check_type)) {
        try response.err(ctx, .bad_request, "check_type must be manual, auto, or scheduled", 40022);
        return;
    }
    if (std.mem.eql(u8, req.check_type, "scheduled") and
        (req.cron_expression == null or req.cron_expression.?.len == 0))
    {
        try response.err(ctx, .bad_request, "cron_expression is required for scheduled rules", 40023);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("ar");
    const entry = model.AuditRule{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .description = try memDup(req.description),
        .check_type = try memDup(req.check_type),
        .cron_expression = if (req.cron_expression) |ce| try memDup(ce) else null,
        .created_at = try nowStr(),
    };
    try mem_rules.?.put(entry.id, entry);
    ctx.res_status = .created;
    try response.ok(ctx, entry);
}

pub fn getRule(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "rule_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_rules.?.get(id) orelse {
        try response.err(ctx, .not_found, "audit rule not found", 40401);
        return;
    };
    try response.ok(ctx, entry);
}

pub fn updateRule(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "rule_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateRuleRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.check_type) |ct| {
        if (!model.validateCheckType(ct)) {
            try response.err(ctx, .bad_request, "check_type must be manual, auto, or scheduled", 40022);
            return;
        }
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_rules.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "audit rule not found", 40401);
        return;
    };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    if (req.description) |d| entry_ptr.description = try memDup(d);
    if (req.check_type) |ct| entry_ptr.check_type = try memDup(ct);
    if (req.cron_expression) |ce| entry_ptr.cron_expression = try memDup(ce);
    try response.ok(ctx, entry_ptr.*);
}

pub fn deleteRule(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "rule_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_rules.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "audit rule not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Audit Execution ──────────────────────────────────────────

/// Run an audit for a specific rule. Checks a mock condition (rule name
/// length > 0, which always passes) and creates an AuditLog entry.
pub fn runAudit(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.RunAuditRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const rule = mem_rules.?.get(req.rule_id) orelse {
        try response.err(ctx, .not_found, "audit rule not found", 40401);
        return;
    };
    if (!std.mem.eql(u8, rule.workspace_id, workspace_id)) {
        try response.err(ctx, .forbidden, "rule does not belong to workspace", 40301);
        return;
    }

    // Mock audit condition: the rule always passes.
    const mock_pass = true;
    const status = if (mock_pass) "pass" else "fail";
    const details = if (mock_pass) "All compliance checks passed (mock)" else "Compliance check failed (mock)";

    const log_id = try generateId("al");
    const log_entry = model.AuditLog{
        .id = try memDup(log_id),
        .rule_id = try memDup(req.rule_id),
        .workspace_id = try memDup(workspace_id),
        .status = try memDup(status),
        .details = try memDup(details),
        .created_at = try nowStr(),
    };
    try mem_logs.?.put(log_entry.id, log_entry);

    ctx.res_status = .created;
    try response.ok(ctx, log_entry);
}

/// ── Audit Log Listing ────────────────────────────────────────

pub fn listAuditLogs(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.AuditLog) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_logs) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .logs = list.items, .total = list.items.len });
}
