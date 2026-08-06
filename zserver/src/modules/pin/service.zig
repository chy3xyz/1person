//! Pin module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_pins`) and
//! exposes the four HTTP-facing operations: `listPins`, `createPin`,
//! `deletePin`, `reorderPins`. The `handler.zig` is a thin delegate;
//! SQL and data shapes live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.pin_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_pins: ?std.StringHashMap(model.PinEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_pins == null) {
        mem_pins = std.StringHashMap(model.PinEntry).init(memAlloc());
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

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getUserId(ctx);
    }

fn memMaxPosition(workspace_id: []const u8, user_id: []const u8) f64 {
    var max: f64 = 0;
    var it = mem_pins.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        if (!std.mem.eql(u8, entry.user_id, user_id)) continue;
        if (entry.position > max) max = entry.position;
    }
    return max;
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

const CreatePinRequest = struct {
    item_type: []const u8,
    item_id: []const u8,
};

const ReorderItem = struct {
    id: []const u8,
    position: f64,
};

const ReorderPinsRequest = struct {
    items: []const ReorderItem,
};

// ──────────────────────────────────────────────────────────────────────
// list
// ──────────────────────────────────────────────────────────────────────

pub fn listPins(ctx: *zfinal.Context) !void {
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

    if (deps.hasPool()) {
        const items = try model.dbListPins(allocator, workspace_id, user_id);
        defer allocator.free(items);
        try ctx.renderJson(items);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.PinResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_pins.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        if (!std.mem.eql(u8, entry.user_id, user_id)) continue;
        try list.append(allocator, model.pinResponseFromEntry(entry));
    }
    try ctx.renderJson(list.items);
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createPin(ctx: *zfinal.Context) !void {
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

    const parsed = try ctx.parseJsonBody(CreatePinRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.validateItemType(req.item_type)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "item_type must be 'issue' or 'project'" });
        return;
    }
    if (req.item_id.len == 0 or !model.looksLikeUuid(req.item_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "item_id is required" });
        return;
    }

    if (deps.hasPool()) {
        if (!(try model.dbItemExists(allocator, req.item_type, req.item_id, workspace_id))) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = if (std.mem.eql(u8, req.item_type, "issue")) "issue not found" else "project not found" });
            return;
        }

        const max_pos = model.dbMaxPosition(workspace_id, user_id);
        const new_pos = max_pos + 1;
        if (try model.dbCreatePin(allocator, workspace_id, user_id, req.item_type, req.item_id, new_pos)) |resp| {
            ctx.res_status = .created;
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create pin" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var it = mem_pins.?.iterator();
    while (it.next()) |e| {
        const other = e.value_ptr.*;
        if (std.mem.eql(u8, other.workspace_id, workspace_id) and std.mem.eql(u8, other.user_id, user_id) and
            std.mem.eql(u8, other.item_type, req.item_type) and std.mem.eql(u8, other.item_id, req.item_id))
        {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "item already pinned" });
            return;
        }
    }

    const id = try model.generateId(allocator, req.item_type);
    const now = try nowString();
    const position = memMaxPosition(workspace_id, user_id) + 1;
    const entry = model.PinEntry{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .user_id = try memDup(user_id),
        .item_type = try memDup(req.item_type),
        .item_id = try memDup(req.item_id),
        .position = position,
        .created_at = try memDup(now),
    };
    try mem_pins.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.pinResponseFromEntry(entry));
}

// ──────────────────────────────────────────────────────────────────────
// delete
// ──────────────────────────────────────────────────────────────────────

pub fn deletePin(ctx: *zfinal.Context) !void {
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
    const item_type = ctx.getPathParam("itemType") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "item_type is required" });
        return;
    };
    const item_id = ctx.getPathParam("itemId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "item_id is required" });
        return;
    };

    if (deps.hasPool()) {
        model.dbDeletePin(workspace_id, user_id, item_type, item_id);
        ctx.res_status = .no_content;
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var it = mem_pins.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (std.mem.eql(u8, entry.workspace_id, workspace_id) and std.mem.eql(u8, entry.user_id, user_id) and
            std.mem.eql(u8, entry.item_type, item_type) and std.mem.eql(u8, entry.item_id, item_id))
        {
            _ = mem_pins.?.fetchRemove(entry.id);
            break;
        }
    }
    ctx.res_status = .no_content;
}

// ──────────────────────────────────────────────────────────────────────
// reorder
// ──────────────────────────────────────────────────────────────────────

pub fn reorderPins(ctx: *zfinal.Context) !void {
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

    const parsed = try ctx.parseJsonBody(ReorderPinsRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (deps.hasPool()) {
        for (req.items) |item| {
            try model.dbReorderPin(allocator, item.position, item.id, workspace_id, user_id);
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        for (req.items) |item| {
            if (mem_pins.?.getPtr(item.id)) |pin| {
                if (std.mem.eql(u8, pin.workspace_id, workspace_id) and std.mem.eql(u8, pin.user_id, user_id)) {
                    pin.position = item.position;
                }
            }
        }
    }
    ctx.res_status = .no_content;
}
