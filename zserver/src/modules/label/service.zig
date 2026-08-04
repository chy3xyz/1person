//! Label module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_labels`)
//! and exposes the five HTTP-facing operations: `listLabels`,
//! `getLabel`, `createLabel`, `updateLabel`, `deleteLabel`. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.label_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_labels: ?std.StringHashMap(model.LabelEntry) = null;

/// Cross-module accessor: returns the in-memory label store so
/// the `model.zig::memFindLabel` probe (used by `issue.attachLabel`)
/// can read it without introducing a service→model import cycle.
/// Returns the `StringHashMap` by value; callers should treat the
/// pointer as borrowed (no inserts via this handle).
pub fn labelStore() *std.StringHashMap(model.LabelEntry) {
    return &(mem_labels orelse blk: {
        mem_labels = std.StringHashMap(model.LabelEntry).init(memAlloc());
        break :blk mem_labels.?;
    });
}

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_labels == null) {
        mem_labels = std.StringHashMap(model.LabelEntry).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

const CreateLabelRequest = struct {
    name: []const u8,
    color: []const u8,
};

const UpdateLabelRequest = struct {
    name: ?[]const u8 = null,
    color: ?[]const u8 = null,
};

// ──────────────────────────────────────────────────────────────────────
// list / get
// ──────────────────────────────────────────────────────────────────────

pub fn listLabels(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (deps.hasPool()) {
        const items = try model.dbListLabels(allocator, workspace_id);
        defer allocator.free(items);
        try ctx.renderJson(.{ .labels = items, .total = items.len });
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.LabelResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_labels.?.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.*.workspace_id, workspace_id)) continue;
        try list.append(allocator, model.labelResponseFromEntry(e.value_ptr.*));
    }
    try ctx.renderJson(.{ .labels = list.items, .total = list.items.len });
}

pub fn getLabel(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const label_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "label_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbGetLabel(workspace_id, label_id)) |resp| {
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "label not found" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_labels.?.get(label_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "label not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "label not found" });
        return;
    }
    try ctx.renderJson(model.labelResponseFromEntry(entry));
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createLabel(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(CreateLabelRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = model.validateName(req.name) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required and must be 32 characters or fewer" });
        return;
    };
    const color = model.normalizeColor(memAlloc(), req.color) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "color must be a 6-digit hex value like #3b82f6" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbLabelNameExists(workspace_id, name)) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "a label with that name already exists" });
            return;
        }
        if (model.dbCreateLabel(workspace_id, name, color)) |resp| {
            ctx.res_status = .created;
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create label" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var it = mem_labels.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.workspace_id, workspace_id) and std.mem.eql(u8, entry.name, name)) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "a label with that name already exists" });
            return;
        }
    }

    const id = try model.generateId(allocator, name);
    const now = try nowString();
    const entry = model.LabelEntry{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(name),
        .color = color,
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_labels.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.labelResponseFromEntry(entry));
}

// ──────────────────────────────────────────────────────────────────────
// update
// ──────────────────────────────────────────────────────────────────────

pub fn updateLabel(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const label_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "label_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(UpdateLabelRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = if (req.name) |n| model.validateName(n) else null;
    if (req.name != null and name == null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required and must be 32 characters or fewer" });
        return;
    }
    const color = if (req.color) |c| model.normalizeColor(memAlloc(), c) catch null else null;
    if (req.color != null and color == null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "color must be a 6-digit hex value like #3b82f6" });
        return;
    }

    if (deps.hasPool()) {
        if (name) |n| {
            if (model.dbLabelNameExists(workspace_id, n)) {
                // Check if the existing label with this name is a different label.
                const existing = model.dbGetLabel(workspace_id, label_id);
                if (existing == null or !std.mem.eql(u8, existing.?.name, n)) {
                    ctx.res_status = .conflict;
                    try ctx.renderJson(.{ .@"error" = "a label with that name already exists" });
                    return;
                }
            }
        }
        if (model.dbUpdateLabel(label_id, workspace_id, name orelse "", color orelse "")) |resp| {
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "label not found" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_labels.?.getPtr(label_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "label not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "label not found" });
        return;
    }
    if (name) |n| {
        var it = mem_labels.?.iterator();
        while (it.next()) |e| {
            const other = e.value_ptr.*;
            if (std.mem.eql(u8, other.id, label_id)) continue;
            if (std.mem.eql(u8, other.workspace_id, workspace_id) and std.mem.eql(u8, other.name, n)) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "a label with that name already exists" });
                return;
            }
        }
        entry.name = try memDup(n);
    }
    if (color) |c| entry.color = c;
    entry.updated_at = try nowString();
    try ctx.renderJson(model.labelResponseFromEntry(entry.*));
}

// ──────────────────────────────────────────────────────────────────────
// delete
// ──────────────────────────────────────────────────────────────────────

pub fn deleteLabel(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const label_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "label_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (model.dbDeleteLabel(label_id, workspace_id)) {
            try response.okNoContent(ctx);
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "label not found" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_labels.?.fetchRemove(label_id)) |kv| {
        const entry = kv.value;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            try mem_labels.?.put(entry.id, entry);
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "label not found" });
            return;
        }
        // Cascade: strip this label id from every issue's join
        // list. Lives in the issue module to keep label→issue
        // dependency one-way (no label.model import of issue
        // service).
        const issue_model = @import("../issue/model.zig");
        _ = issue_model.memCascadeDeleteLabel(label_id);
    }
    try response.okNoContent(ctx);
}
