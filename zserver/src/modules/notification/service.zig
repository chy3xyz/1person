//! Notification service — in-memory CRUD for templates and simulated
//! notification delivery.
//!
//! Operates entirely in no-DB mode using a page-allocator-backed
//! StringHashMap. All per-workspace scoping is enforced on read/write.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

pub const NotificationTemplate = model.NotificationTemplate;
pub const NotificationLog = model.NotificationLog;
pub const NotificationChannel = model.NotificationChannel;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_templates: ?std.StringHashMap(model.NotificationTemplate) = null;
var mem_logs: ?std.StringHashMap(model.NotificationLog) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memDup(text: []const u8) ![]const u8 {
        return common_mem.memDup(text);
    }

fn memInit() !void {
    if (mem_templates == null) {
        mem_templates = std.StringHashMap(model.NotificationTemplate).init(memAlloc());
        mem_logs = std.StringHashMap(model.NotificationLog).init(memAlloc());
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
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

/// ── Template CRUD ───────────────────────────────────────────────

pub fn listTemplates(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.NotificationTemplate) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_templates) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .templates = list.items, .total = list.items.len });
}

pub fn createTemplate(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateTemplateRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }
    if (req.channel.len == 0) {
        try response.err(ctx, .bad_request, "channel is required", 40022);
        return;
    }
    if (model.NotificationChannel.fromStr(req.channel) == null) {
        try response.err(ctx, .bad_request, "unsupported channel", 40023);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("ntpl");
    const entry = model.NotificationTemplate{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .channel = try memDup(req.channel),
        .subject_template = try memDup(req.subject_template),
        .body_template = try memDup(req.body_template),
    };
    try mem_templates.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn getTemplate(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "template_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_templates.?.get(id) orelse {
        try response.err(ctx, .not_found, "notification template not found", 40401);
        return;
    };
    try ctx.renderJson(entry);
}

pub fn updateTemplate(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "template_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateTemplateRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_templates.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "notification template not found", 40401);
        return;
    };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    if (req.channel) |c| {
        if (model.NotificationChannel.fromStr(c) == null) {
            try response.err(ctx, .bad_request, "unsupported channel", 40023);
            return;
        }
        entry_ptr.channel = try memDup(c);
    }
    if (req.subject_template) |s| entry_ptr.subject_template = try memDup(s);
    if (req.body_template) |b| entry_ptr.body_template = try memDup(b);
    try ctx.renderJson(entry_ptr.*);
}

pub fn deleteTemplate(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "template_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_templates.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "notification template not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Send notification (simulated) ───────────────────────────────

pub fn send(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);

    const raw = try ctx.getBodyText();
    defer ctx.allocator.free(raw);
    const parsed_body = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
        try response.err(ctx, .bad_request, "invalid JSON body", 40024);
        return;
    };
    defer parsed_body.deinit();

    const root = parsed_body.value;
    if (root != .object) {
        try response.err(ctx, .bad_request, "expected JSON object", 40025);
        return;
    }

    const template_id = if (root.object.get("template_id")) |v| blk: {
        if (v == .string) break :blk v.string;
        try response.err(ctx, .bad_request, "template_id must be a string", 40026);
        return;
    } else {
        try response.err(ctx, .bad_request, "template_id is required", 40027);
        return;
    };

    const user_id = if (root.object.get("user_id")) |v| blk: {
        if (v == .string) break :blk v.string;
        try response.err(ctx, .bad_request, "user_id must be a string", 40028);
        return;
    } else {
        try response.err(ctx, .bad_request, "user_id is required", 40029);
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const template = mem_templates.?.get(template_id) orelse {
        try response.err(ctx, .not_found, "notification template not found", 40401);
        return;
    };

    const log_id = try generateId("nlog");
    const log_entry = model.NotificationLog{
        .id = try memDup(log_id),
        .template_id = try memDup(template_id),
        .user_id = try memDup(user_id),
        .channel = try memDup(template.channel),
        .status = try memDup("sent"),
        .created_at = try nowStr(),
    };
    try mem_logs.?.put(log_entry.id, log_entry);

    ctx.res_status = .created;
    try ctx.renderJson(log_entry);
}

/// ── Log retrieval ───────────────────────────────────────────────

pub fn getLogs(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const user_id = ctx.getPara("user_id") catch null;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.NotificationLog) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_logs) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            const log = kv.value_ptr.*;
            if (user_id) |uid| {
                if (!std.mem.eql(u8, log.user_id, uid)) continue;
            }
            try list.append(ctx.allocator, log);
        }
    }
    try ctx.renderJson(.{ .logs = list.items, .total = list.items.len });
}

/// ── List channels ───────────────────────────────────────────────

pub fn listChannels(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const channels = [_][]const u8{ "email", "sms", "wechat", "telegram", "discord", "push", "in_app" };
    try ctx.renderJson(.{ .channels = &channels });
}
