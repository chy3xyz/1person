//! Content-matrix service — in-memory CRUD for platforms and
//! multi-platform content distribution engine.
//!
//! Operates in no-DB mode using a page-allocator-backed StringHashMap.
//! All per-workspace scoping is enforced on read/write.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const PlatformConfig = model.PlatformConfig;
pub const DistributeResult = model.DistributeResult;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_platforms: ?std.StringHashMap(model.PlatformConfig) = null;
var mem_results: ?std.StringHashMap(model.DistributeResult) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_platforms == null) {
        mem_platforms = std.StringHashMap(model.PlatformConfig).init(memAlloc());
        mem_results = std.StringHashMap(model.DistributeResult).init(memAlloc());
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
    return ctx.attributes.get("workspace_id");
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

/// ── Platform CRUD ───────────────────────────────────────────────

pub fn listPlatforms(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.PlatformConfig) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_platforms) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .platforms = list.items, .total = list.items.len });
}

pub fn createPlatform(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreatePlatformRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.validatePlatform(req.name, req.adapter_type)) {
        try response.err(ctx, .bad_request, "name and adapter_type are required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("pf");
    const entry = model.PlatformConfig{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .adapter_type = try memDup(req.adapter_type),
        .created_at = try nowStr(),
    };
    try mem_platforms.?.put(entry.id, entry);
    ctx.res_status = .created;
    try response.ok(ctx, entry);
}

pub fn getPlatform(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "platform_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_platforms.?.get(id) orelse {
        try response.err(ctx, .not_found, "platform not found", 40401);
        return;
    };
    try response.ok(ctx, entry);
}

pub fn updatePlatform(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "platform_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdatePlatformRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_platforms.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "platform not found", 40401);
        return;
    };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    if (req.adapter_type) |a| entry_ptr.adapter_type = try memDup(a);
    try response.ok(ctx, entry_ptr.*);
}

pub fn deletePlatform(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "platform_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_platforms.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "platform not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Content Distribution ────────────────────────────────────────

fn adaptContent(adapter_type: []const u8, original: []const u8) []const u8 {
    // Generate pseudo-adapted content based on the adapter type.
    if (std.mem.eql(u8, adapter_type, "blog")) {
        const title = extractFirstLine(original);
        return std.fmt.allocPrint(memAlloc(), "<article><h1>{s}</h1><section>{s}</section></article>", .{ title, original }) catch @panic("OOM");
    }
    if (std.mem.eql(u8, adapter_type, "twitter")) {
        var excerpt: []const u8 = original;
        if (excerpt.len > 140) excerpt = excerpt[0..140];
        return std.fmt.allocPrint(memAlloc(), "{s}... #distributed", .{excerpt}) catch @panic("OOM");
    }
    // Default pass-through
    return memDup(original) catch @panic("OOM");
}

fn extractFirstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n')) |pos| {
        return text[0..pos];
    }
    return text;
}

pub fn distributeContent(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.DistributeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.original_content.len == 0) {
        try response.err(ctx, .bad_request, "original_content is required", 40021);
        return;
    }
    if (req.platforms.len == 0) {
        try response.err(ctx, .bad_request, "platforms must not be empty", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var records: std.ArrayList(model.DistributeResult) = .empty;
    defer records.deinit(ctx.allocator);

    for (req.platforms) |pf_id| {
        const pf = mem_platforms.?.get(pf_id) orelse {
            try response.err(ctx, .not_found, "platform not found", 40401);
            return;
        };
        if (!std.mem.eql(u8, pf.workspace_id, workspace_id)) {
            try response.err(ctx, .forbidden, "platform does not belong to workspace", 40301);
            return;
        }

        _ = adaptContent(pf.adapter_type, req.original_content);

        const url = try std.fmt.allocPrint(memAlloc(), "https://{s}.example.com/post/{s}", .{ pf.adapter_type, pf_id });
        const rec_id = try generateId("dr");
        const rec = model.DistributeResult{
            .id = try memDup(rec_id),
            .platform = try memDup(pf_id),
            .platform_name = try memDup(pf.name),
            .content_url = try memDup(url),
            .status = try memDup("ok"),
            .created_at = try nowStr(),
        };
        try mem_results.?.put(rec.id, rec);
        try records.append(ctx.allocator, rec);
    }

    ctx.res_status = .created;
    try response.ok(ctx, .{ .results = records.items, .total = records.items.len });
}

/// ── Result Listing ──────────────────────────────────────────────

pub fn listResults(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.DistributeResult) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_results) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .results = list.items, .total = list.items.len });
}

pub fn getResult(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "result_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_results.?.get(id) orelse {
        try response.err(ctx, .not_found, "distribution result not found", 40402);
        return;
    };
    try response.ok(ctx, entry);
}
