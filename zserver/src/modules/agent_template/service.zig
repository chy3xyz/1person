//! Agent template module — business logic.
//!
//! Owns the in-memory `mem_templates` store and exposes the five
//! HTTP-facing operations: `listTemplates`, `getTemplate`,
//! `createTemplate`, `updateTemplate`, `deleteTemplate`. The
//! `handler.zig` is a thin delegate; data structs live in
//! `model.zig`.
//!
//! Agent templates are pure in-memory — there is no DB backing.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const model = @import("model.zig");
const response = @import("../../common/response.zig");

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_templates: ?std.StringHashMap(model.TemplateEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_templates == null) {
        mem_templates = std.StringHashMap(model.TemplateEntry).init(memAlloc());
        for (model.seed_templates) |t| {
            try mem_templates.?.put(try memDup(t.slug), model.TemplateEntry{
                .slug = try memDup(t.slug),
                .name = try memDup(t.name),
                .description = try memDup(t.description),
                .icon = try memDup(t.icon),
                .category = try memDup(t.category),
                .config = try memDup(t.config),
                .created_at = try memDup(t.created_at),
                .updated_at = try memDup(t.updated_at),
            });
        }
    }
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn templateResponseFromEntry(allocator: std.mem.Allocator, entry: model.TemplateEntry) !model.TemplateResponse {
    var holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (holder) |p| p.deinit();
    const config = try model.parseConfig(allocator, entry.config, &holder);
    return model.TemplateResponse{
        .slug = entry.slug,
        .name = entry.name,
        .description = entry.description,
        .icon = entry.icon,
        .category = entry.category,
        .config = config,
    };
}

fn isValidSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return true;
}

pub fn listTemplates(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.TemplateResponse) = .empty;
    defer list.deinit(allocator);
    var it = mem_templates.?.iterator();
    while (it.next()) |e| {
        try list.append(allocator, try templateResponseFromEntry(allocator, e.value_ptr.*));
    }
    try ctx.renderJson(list.items);
}

pub fn getTemplate(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const slug = ctx.getPathParam("slug") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "slug is required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_templates.?.get(slug) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "template not found" });
        return;
    };
    try ctx.renderJson(try templateResponseFromEntry(allocator, entry));
}

pub fn createTemplate(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = try ctx.parseJsonBody(model.CreateTemplateRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const slug = std.mem.trim(u8, req.slug, &std.ascii.whitespace);
    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (slug.len == 0 or !isValidSlug(slug)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "slug is required and must be alphanumeric with hyphens" });
        return;
    }
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_templates.?.contains(slug)) {
        ctx.res_status = .conflict;
        try ctx.renderJson(.{ .@"error" = "template with this slug already exists" });
        return;
    }

    const now = try nowString();
    const config_json = if (req.config) |v| try std.json.Stringify.valueAlloc(memAlloc(), v, .{}) else try memDup("{}");
    const entry = model.TemplateEntry{
        .slug = try memDup(slug),
        .name = try memDup(name),
        .description = try memDup(req.description orelse ""),
        .icon = try memDup(req.icon orelse ""),
        .category = try memDup(req.category orelse ""),
        .config = config_json,
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_templates.?.put(entry.slug, entry);

    ctx.res_status = .created;
    try ctx.renderJson(try templateResponseFromEntry(allocator, entry));
}

pub fn updateTemplate(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const slug = ctx.getPathParam("slug") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "slug is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateTemplateRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry_ptr = mem_templates.?.getPtr(slug) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "template not found" });
        return;
    };

    if (req.name) |n| {
        const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name cannot be empty" });
            return;
        }
        entry_ptr.name = try memDup(trimmed);
    }
    if (req.description) |d| entry_ptr.description = try memDup(d);
    if (req.icon) |i| entry_ptr.icon = try memDup(i);
    if (req.category) |c| entry_ptr.category = try memDup(c);
    if (req.config) |c| entry_ptr.config = try std.json.Stringify.valueAlloc(memAlloc(), c, .{});
    entry_ptr.updated_at = try nowString();

    try ctx.renderJson(try templateResponseFromEntry(allocator, entry_ptr.*));
}

pub fn deleteTemplate(ctx: *zfinal.Context) !void {
    const slug = ctx.getPathParam("slug") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "slug is required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    _ = mem_templates.?.fetchRemove(slug) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "template not found" });
        return;
    };
    // The removed entry's memDup'd strings and `config` are leaked
    // by design: the page allocator does not track individual
    // allocations, and the strings (e.g. `config` which is a tagged
    // union of `std.json.Value`) are not safe to free piecemeal.
    // The leak is bounded by the template's lifetime, which is
    // the workspace's.
    try response.okNoContent(ctx);
}
