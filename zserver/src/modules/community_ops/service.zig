//! Community ops service — in-memory CRUD for groups, member management,
//! announcements and daily digest. No-DB mode using page-allocator-backed
//! StringHashMap.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const CommunityGroup = model.CommunityGroup;
const Announcement = model.Announcement;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_groups: ?std.StringHashMap(CommunityGroup) = null;
var mem_announcements: ?std.StringHashMap(Announcement) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memDup(text: []const u8) ![]const u8 {
        return common_mem.memDup(text);
    }

fn memInit() !void {
    if (mem_groups == null) {
        mem_groups = std.StringHashMap(CommunityGroup).init(memAlloc());
        mem_announcements = std.StringHashMap(Announcement).init(memAlloc());
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
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

// ── Group CRUD ──────────────────────────────────────────────────

pub fn listGroups(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(CommunityGroup) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_groups) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .groups = list.items, .total = list.items.len });
}

pub fn createGroup(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateGroupRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("cg");
    const entry = CommunityGroup{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .member_count = 0,
    };
    try mem_groups.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn getGroup(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_groups.?.get(id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };
    try ctx.renderJson(entry);
}

pub fn deleteGroup(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_groups.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

// ── Membership ──────────────────────────────────────────────────

pub fn addMember(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_groups.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };
    entry_ptr.member_count += 1;
    try ctx.renderJson(entry_ptr.*);
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_groups.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };
    if (entry_ptr.member_count > 0) {
        entry_ptr.member_count -= 1;
    }
    try ctx.renderJson(entry_ptr.*);
}

// ── Announcements ───────────────────────────────────────────────

pub fn createAnnouncement(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const group_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.CreateAnnouncementRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.content.len == 0) {
        try response.err(ctx, .bad_request, "content is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // Verify group exists
    _ = mem_groups.?.get(group_id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };

    const id = try generateId("ann");
    const scheduled = if (req.scheduled_at) |s| try memDup(s) else null;
    const entry = Announcement{
        .id = try memDup(id),
        .group_id = try memDup(group_id),
        .content = try memDup(req.content),
        .scheduled_at = scheduled,
        .published_at = null,
    };
    try mem_announcements.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn publishAnnouncement(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "announcement_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_announcements.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "announcement not found", 40402);
        return;
    };
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const ts_str = try std.fmt.allocPrint(memAlloc(), "{d}", .{ts});
    entry_ptr.published_at = ts_str;
    try ctx.renderJson(entry_ptr.*);
}

// ── Daily Digest ────────────────────────────────────────────────

pub fn getDailyDigest(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const group_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "group_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const group = mem_groups.?.get(group_id) orelse {
        try response.err(ctx, .not_found, "group not found", 40401);
        return;
    };

    // Collect published announcements for this group as mock recent activity.
    var activity: std.ArrayList([]const u8) = .empty;
    defer activity.deinit(ctx.allocator);
    if (mem_announcements) |*ma| {
        var it = ma.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.group_id, group_id) and kv.value_ptr.published_at != null) {
                try activity.append(ctx.allocator, kv.value_ptr.content);
            }
        }
    }
    // If no published announcements, provide a default activity line.
    if (activity.items.len == 0) {
        try activity.append(ctx.allocator, "No recent activity");
    }

    try ctx.renderJson(model.DailyDigestResponse{
        .group_id = group.id,
        .member_count = group.member_count,
        .recent_activity = try ctx.allocator.dupe([]const u8, activity.items),
    });
}
