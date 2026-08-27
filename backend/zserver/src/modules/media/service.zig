//! Media module — business logic.
//!
//! Owns the per-process in-memory state for the media asset store.
//! All operations are no-DB (in-memory HashMap). No real file I/O is
//! performed — upload creates a record with a mock URL.
//!
//! `handler.zig` is a thin delegate; data shapes live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

pub const MediaAssetResponse = model.MediaAssetResponse;

const log = std.log.scoped(.media_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_assets: ?std.StringHashMap(model.MediaAsset) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memInit() !void {
    if (mem_assets == null) {
        mem_assets = std.StringHashMap(model.MediaAsset).init(model.memAlloc());
    }
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn io() std.Io {
    return zfinal.io_instance.io;
}

fn memDup(text: []const u8) ![]const u8 {
    return try model.memAlloc().dupe(u8, text);
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

fn nowString() ![]const u8 {
        return common_mem.nowString();
    }

fn buildMockURL(id: []const u8, _: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const cfg = g_cfg orelse {
        return try std.fmt.allocPrint(allocator, "/api/media/{s}/file", .{id});
    };
    if (cfg.public_url.len == 0) {
        return try std.fmt.allocPrint(allocator, "/api/media/{s}/file", .{id});
    }
    return try std.fmt.allocPrint(allocator, "{s}/api/media/{s}/file", .{ cfg.public_url, id });
}

// ──────────────────────────────────────────────────────────────────────
// handlers
// ──────────────────────────────────────────────────────────────────────

/// Simulate an upload: creates an in-memory MediaAsset record with a
/// mock URL. No real file I/O. Request body: JSON with filename,
/// optional mime_type, size_bytes, caption.
pub fn upload(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UploadRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.filename.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "filename is required" });
        return;
    }

    const id = try generateId(allocator, req.filename);
    const url = try buildMockURL(id, req.filename, allocator);
    const created_at = try nowString();

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const asset = model.MediaAsset{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .filename = try memDup(req.filename),
        .mime_type = try memDup(req.mime_type),
        .size_bytes = req.size_bytes,
        .url = try memDup(url),
        .caption = try memDup(req.caption),
        .created_at = created_at,
    };
    try mem_assets.?.put(asset.id, asset);

    const resp = model.responseFromAsset(asset);
    try ctx.renderJson(resp);
}

/// List all media assets for the current workspace.
pub fn list(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var items: std.ArrayList(model.MediaAssetResponse) = .empty;
    defer items.deinit(ctx.allocator);

    var it = mem_assets.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        try items.append(ctx.allocator, model.responseFromAsset(entry));
    }

    try ctx.renderJson(.{ .assets = items.items });
}

/// Get a single media asset by ID.
pub fn get(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const asset_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "asset_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_assets.?.get(asset_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "media asset not found" });
        return;
    };

    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "media asset not found" });
        return;
    }

    try ctx.renderJson(model.responseFromAsset(entry));
}

/// Delete a media asset by ID.
pub fn deleteAsset(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const asset_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "asset_id is required" });
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_assets.?.get(asset_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "media asset not found" });
        return;
    };

    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "media asset not found" });
        return;
    }

    _ = mem_assets.?.remove(asset_id);
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .deleted = true });
}
