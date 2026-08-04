//! Inbox module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_inbox`
//! table) and exposes the eleven HTTP-facing operations: `listInbox`,
//! `markInboxRead`, `archiveInboxItem`, `countUnreadInbox`,
//! `markAllInboxRead`, `archiveAllInbox`, `archiveAllReadInbox`,
//! `archiveCompletedInbox`, `listInboxSince`, `purgeInboxPair`,
//! `exportInboxEvents`. The `handler.zig` is a thin delegate; SQL
//! and data shapes live in `model.zig`.
//!
//! The realtime integration (`realtime.publishInbox`,
//! `realtime.appendAudit`, `realtime.replaySnapshot`,
//! `realtime.replaySnapshotParsed`, `realtime.ringApproxBytes`,
//! `realtime.purgePair`) is imported from `src/handlers/realtime.zig`
//! to avoid re-implementing the WebSocket ring buffer and the audit
//! log writer here.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const pagination = @import("../../common/pagination.zig");
const realtime = @import("../../modules/realtime/service.zig");
const model = @import("model.zig");

const log = std.log.scoped(.inbox_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_inbox: ?std.StringHashMap(model.InboxEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_inbox == null) {
        mem_inbox = std.StringHashMap(model.InboxEntry).init(memAlloc());
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

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

/// Build a JSON payload describing an inbox event and dispatch it
/// through the realtime broadcaster. Best-effort: callers run this
/// after a successful write and treat it as fire-and-forget. The
/// allocator is expected to be `ctx.allocator`; ownership of the
/// formatted payload stays with `publishInbox` (it copies before
/// returning), so the caller does not need to free it.
fn notifyInboxChange(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    user_id: []const u8,
    inbox_id: []const u8,
    action: []const u8,
    count: usize,
) void {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"inbox_updated\",\"inbox_id\":\"{s}\",\"workspace_id\":\"{s}\",\"user_id\":\"{s}\",\"action\":\"{s}\",\"count\":{d}}}",
        .{ inbox_id, workspace_id, user_id, action, count },
    ) catch return;
    defer allocator.free(payload);
    realtime.publishInbox(workspace_id, user_id, payload);
}

fn inboxResponseFromEntry(allocator: std.mem.Allocator, entry: model.InboxEntry, holder: *?std.json.Parsed(std.json.Value)) !model.InboxResponse {
    return model.InboxResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .recipient_type = entry.recipient_type,
        .recipient_id = entry.recipient_id,
        .type = entry.type,
        .severity = entry.severity,
        .issue_id = if (entry.issue_id.len > 0) entry.issue_id else null,
        .title = entry.title,
        .body = if (entry.body.len > 0) entry.body else null,
        .read = entry.read,
        .archived = entry.archived,
        .created_at = entry.created_at,
        .issue_status = if (entry.issue_status.len > 0) entry.issue_status else null,
        .actor_type = if (entry.actor_type.len > 0) entry.actor_type else null,
        .actor_id = if (entry.actor_id.len > 0) entry.actor_id else null,
        .details = try model.parseDetails(allocator, entry.details, holder),
    };
}

fn inboxResponseFromRow(allocator: std.mem.Allocator, rs: *zfinal.ResultSet, row: usize, holder: *?std.json.Parsed(std.json.Value)) !model.InboxResponse {
    const r = &rs.rows.items[row];
    const details = r.getText(15) orelse "";
    const read_text = r.getText(9) orelse "";
    const archived_text = r.getText(10) orelse "";
    const isTrue = struct {
        fn check(t: []const u8) bool {
            return std.mem.eql(u8, t, "t") or
                std.mem.eql(u8, t, "true") or
                std.mem.eql(u8, t, "1");
        }
    }.check;

    // Dupe all text fields into the caller's allocator so the returned
    // struct does not reference result-set memory that will be freed by
    // defer rs.deinit().
    const id = try allocator.dupe(u8, r.getText(0) orelse "");
    errdefer allocator.free(id);
    const workspace_id = try allocator.dupe(u8, r.getText(1) orelse "");
    errdefer allocator.free(workspace_id);
    const recipient_type = try allocator.dupe(u8, r.getText(2) orelse "");
    errdefer allocator.free(recipient_type);
    const recipient_id = try allocator.dupe(u8, r.getText(3) orelse "");
    errdefer allocator.free(recipient_id);
    const tx_type = try allocator.dupe(u8, r.getText(4) orelse "");
    errdefer allocator.free(tx_type);
    const severity = try allocator.dupe(u8, r.getText(5) orelse "");
    errdefer allocator.free(severity);
    const issue_id: ?[]const u8 = if (r.getText(6)) |v| blk: {
        const dup = try allocator.dupe(u8, v);
        break :blk dup;
    } else null;
    errdefer if (issue_id) |v| allocator.free(v);
    const title = try allocator.dupe(u8, r.getText(7) orelse "");
    errdefer allocator.free(title);
    const body: ?[]const u8 = if (r.getText(8)) |v| blk: {
        const dup = try allocator.dupe(u8, v);
        break :blk dup;
    } else null;
    errdefer if (body) |v| allocator.free(v);
    const created_at = try allocator.dupe(u8, r.getText(11) orelse "");
    errdefer allocator.free(created_at);
    const issue_status: ?[]const u8 = if (r.getText(12)) |v| blk: {
        const dup = try allocator.dupe(u8, v);
        break :blk dup;
    } else null;
    errdefer if (issue_status) |v| allocator.free(v);
    const actor_type: ?[]const u8 = if (r.getText(13)) |v| blk: {
        const dup = try allocator.dupe(u8, v);
        break :blk dup;
    } else null;
    errdefer if (actor_type) |v| allocator.free(v);
    const actor_id: ?[]const u8 = if (r.getText(14)) |v| blk: {
        const dup = try allocator.dupe(u8, v);
        break :blk dup;
    } else null;
    errdefer if (actor_id) |v| allocator.free(v);

    return model.InboxResponse{
        .id = id,
        .workspace_id = workspace_id,
        .recipient_type = recipient_type,
        .recipient_id = recipient_id,
        .type = tx_type,
        .severity = severity,
        .issue_id = issue_id,
        .title = title,
        .body = body,
        .read = isTrue(read_text),
        .archived = isTrue(archived_text),
        .created_at = created_at,
        .issue_status = issue_status,
        .actor_type = actor_type,
        .actor_id = actor_id,
        .details = try model.parseDetails(allocator, details, holder),
    };
}

pub fn listInbox(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        var rs = try d.queryParams(
            "SELECT id, workspace_id, recipient_type, recipient_id, type, severity, issue_id, " ++
                "title, body, read, archived, created_at, " ++
                "(SELECT status FROM issue WHERE id = inbox_item.issue_id) AS issue_status, " ++
                "actor_type, actor_id, details " ++
                "FROM inbox_item WHERE workspace_id = $1::uuid AND recipient_type = 'member' " ++
                "AND recipient_id = $2::uuid AND archived = false ORDER BY created_at DESC",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();

        var list: std.ArrayList(model.InboxResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            var holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (holder) |p| p.deinit();
            try list.append(allocator, try inboxResponseFromRow(allocator, &rs, i, &holder));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.InboxResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry.recipient_id, user_id)) continue;
            if (entry.archived) continue;
            var holder: ?std.json.Parsed(std.json.Value) = null;
            defer if (holder) |p| p.deinit();
            try list.append(allocator, try inboxResponseFromEntry(allocator, entry, &holder));
        }
        try ctx.renderJson(list.items);
    }
}

fn loadInboxItem(allocator: std.mem.Allocator, ctx: *zfinal.Context, item_id: []const u8) !?model.InboxResponse {
    const workspace_id = getWorkspaceId(ctx) orelse return null;
    const user_id = getUserId(ctx) orelse return null;

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, workspace_id, recipient_type, recipient_id, type, severity, issue_id, " ++
                "title, body, read, archived, created_at, " ++
                "(SELECT status FROM issue WHERE id = inbox_item.issue_id) AS issue_status, " ++
                "actor_type, actor_id, details " ++
                "FROM inbox_item WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $3::uuid",
            &[_]SqlParam{
                .{ .text = item_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        return try inboxResponseFromRow(allocator, &rs, 0, &holder);
    } else {
        try memInit();
        const entry = mem_inbox.?.get(item_id) orelse return null;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
        if (!std.mem.eql(u8, entry.recipient_type, "member")) return null;
        if (!std.mem.eql(u8, entry.recipient_id, user_id)) return null;
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        return try inboxResponseFromEntry(allocator, entry, &holder);
    }
}

pub fn markInboxRead(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const item_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "inbox_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET read = true WHERE id = $1::uuid RETURNING id, workspace_id, " ++
                "recipient_type, recipient_id, type, severity, issue_id, title, body, read, " ++
                "archived, created_at, (SELECT status FROM issue WHERE id = inbox_item.issue_id) AS issue_status, " ++
                "actor_type, actor_id, details",
            &[_]SqlParam{.{ .text = item_id }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "inbox item not found" });
            return;
        }
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        try ctx.renderJson(try inboxResponseFromRow(allocator, &rs, 0, &holder));
        // Realtime notify: prefer the row's workspace/recipient (which match
        // the inbox item) over the request context, so cross-workspace
        // updates still attribute the event correctly.
        const ws_id = rs.rows.items[0].getText(1) orelse "";
        const rcpt = rs.rows.items[0].getText(3) orelse "";
        notifyInboxChange(allocator, ws_id, rcpt, item_id, "read", 1);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_inbox.?.getPtr(item_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "inbox item not found" });
            return;
        };
        entry_ptr.read = true;
        const ws_id = entry_ptr.workspace_id;
        const rcpt = entry_ptr.recipient_id;
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        try ctx.renderJson(try inboxResponseFromEntry(allocator, entry_ptr.*, &holder));
        notifyInboxChange(allocator, ws_id, rcpt, item_id, "read", 1);
    }
}

pub fn archiveInboxItem(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const item_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "inbox_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET archived = true WHERE id = $1::uuid RETURNING id, workspace_id, " ++
                "recipient_type, recipient_id, type, severity, issue_id, title, body, read, " ++
                "archived, created_at, (SELECT status FROM issue WHERE id = inbox_item.issue_id) AS issue_status, " ++
                "actor_type, actor_id, details",
            &[_]SqlParam{.{ .text = item_id }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "inbox item not found" });
            return;
        }
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        try ctx.renderJson(try inboxResponseFromRow(allocator, &rs, 0, &holder));
        const ws_id = rs.rows.items[0].getText(1) orelse "";
        const rcpt = rs.rows.items[0].getText(3) orelse "";
        notifyInboxChange(allocator, ws_id, rcpt, item_id, "archive", 1);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_inbox.?.getPtr(item_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "inbox item not found" });
            return;
        };
        entry_ptr.archived = true;
        const ws_id = entry_ptr.workspace_id;
        const rcpt = entry_ptr.recipient_id;
        var holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (holder) |p| p.deinit();
        try ctx.renderJson(try inboxResponseFromEntry(allocator, entry_ptr.*, &holder));
        notifyInboxChange(allocator, ws_id, rcpt, item_id, "archive", 1);
    }
}

pub fn countUnreadInbox(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT COUNT(*) FROM inbox_item WHERE workspace_id = $1::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $2::uuid AND read = false AND archived = false",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        const count: i64 = @intCast(std.fmt.parseInt(i64, rs.rows.items[0].getText(0) orelse "0", 10) catch 0);
        try ctx.renderJson(.{ .count = count });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var count: i64 = 0;
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry.recipient_id, user_id)) continue;
            if (entry.read) continue;
            if (entry.archived) continue;
            count += 1;
        }
        try ctx.renderJson(.{ .count = count });
    }
}

pub fn markAllInboxRead(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET read = true WHERE workspace_id = $1::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $2::uuid AND archived = false RETURNING id",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        const count = rs.rows.items.len;
        // Best-effort realtime notification; ignore alloc failures.
        notifyInboxChange(allocator, workspace_id, user_id, "", "read", count);
        try ctx.renderJson(.{ .count = count });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var count: usize = 0;
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry_ptr = e.value_ptr;
            if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_id, user_id)) continue;
            if (entry_ptr.archived) continue;
            if (!entry_ptr.read) {
                entry_ptr.read = true;
                count += 1;
            }
        }
        notifyInboxChange(allocator, workspace_id, user_id, "", "read", count);
        try ctx.renderJson(.{ .count = count });
    }
}

pub fn archiveAllInbox(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET archived = true WHERE workspace_id = $1::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $2::uuid AND archived = false RETURNING id",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        const count = rs.rows.items.len;
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var count: usize = 0;
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry_ptr = e.value_ptr;
            if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_id, user_id)) continue;
            if (!entry_ptr.archived) {
                entry_ptr.archived = true;
                count += 1;
            }
        }
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    }
}

pub fn archiveAllReadInbox(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET archived = true WHERE workspace_id = $1::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $2::uuid " ++
                "AND read = true AND archived = false RETURNING id",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        const count = rs.rows.items.len;
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var count: usize = 0;
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry_ptr = e.value_ptr;
            if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_id, user_id)) continue;
            if (entry_ptr.read and !entry_ptr.archived) {
                entry_ptr.archived = true;
                count += 1;
            }
        }
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    }
}

pub fn archiveCompletedInbox(ctx: *zfinal.Context) !void {
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

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "UPDATE inbox_item SET archived = true WHERE workspace_id = $1::uuid " ++
                "AND recipient_type = 'member' AND recipient_id = $2::uuid AND archived = false " ++
                "AND issue_id IS NOT NULL AND (SELECT status FROM issue WHERE id = inbox_item.issue_id) IN ('done', 'cancelled') " ++
                "RETURNING id",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        const count = rs.rows.items.len;
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var count: usize = 0;
        var it = mem_inbox.?.iterator();
        while (it.next()) |e| {
            const entry_ptr = e.value_ptr;
            if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_type, "member")) continue;
            if (!std.mem.eql(u8, entry_ptr.recipient_id, user_id)) continue;
            if (entry_ptr.archived) continue;
            if (entry_ptr.issue_id.len > 0 and
                (std.mem.eql(u8, entry_ptr.issue_status, "done") or std.mem.eql(u8, entry_ptr.issue_status, "cancelled")))
            {
                entry_ptr.archived = true;
                count += 1;
            }
        }
        notifyInboxChange(allocator, workspace_id, user_id, "", "archive", count);
        try ctx.renderJson(.{ .count = count });
    }
}

pub fn listInboxSince(ctx: *zfinal.Context) !void {
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

    const since_seq = try pagination.parseSinceSeq(ctx);
    const max_bytes_str = (try ctx.getPara("max_bytes")) orelse "0";
    const max_bytes_opt: ?usize = blk: {
        const parsed = std.fmt.parseInt(u64, max_bytes_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "max_bytes must be a non-negative integer" });
            return;
        };
        if (parsed == 0) break :blk null;
        break :blk @as(usize, @intCast(parsed));
    };
    // `?ring_bytes=` is a presence-only flag; any non-empty value
    // instructs the handler to include a sibling `ring_bytes` field in
    // the response. The value of the parameter is ignored — the
    // handler always reports the current ring footprint measured via
    // `realtime.ringApproxBytes`. Invalid (empty) values fall through
    // to the default "absent" behaviour so a stray `?ring_bytes` with
    // no `=` is a no-op rather than an error.
    const ring_bytes_present = blk: {
        const raw = (try ctx.getPara("ring_bytes")) orelse break :blk false;
        break :blk raw.len > 0;
    };

    // Read the per-(workspace, user) ring buffer. Each `events[i]` is a
    // parsed `std.json.Value` backed by the arena in `holders[i]`. After
    // we know how many events we want to keep (see truncation block
    // below), we slice the original `events` / `holders` arrays down
    // to the kept prefix and free the rest. The trailing defer walks
    // the holders we kept so the matching arenas are released *after*
    // `renderJson` has finished serialising the values.
    const snapshot = try realtime.replaySnapshotParsed(
        ctx.allocator,
        workspace_id,
        user_id,
        since_seq,
    );

    // Distinguish a service-account caller (X-Service-Token bypass via
    // `RequireServiceOrWorkspaceRole`) from a real workspace member. The
    // log line is best-effort and never blocks the response itself.
    const actor_kind: []const u8 = if (ctx.attributes.get("service_actor") != null)
        "service_actor"
    else if (ctx.attributes.get("workspace_role")) |role|
        role
    else
        "unknown";
    const actor_user_id = ctx.attributes.get("user_id") orelse "";
    realtime.appendAudit(
        actor_kind,
        actor_user_id,
        "inbox.replay",
        workspace_id,
        user_id,
        "manual",
        &.{},
    );

    // Apply the optional `?max_bytes=` cap. We keep the *earliest*
    // envelopes that fit (so the response still represents the oldest
    // unseen events) and drop the rest. When the cap is absent the full
    // snapshot is returned and `truncated` is false. We serialise each
    // parsed event to measure its on-wire size rather than trusting
    // `event` byte length — the JSON form is what actually counts.
    var kept_len: usize = snapshot.events.len;
    var truncated = false;
    var sent_bytes: usize = 0;
    if (max_bytes_opt) |cap| {
        kept_len = 0;
        for (snapshot.events) |event| {
            const size = try measureParsedEvent(ctx.allocator, event);
            if (sent_bytes + size > cap) {
                truncated = true;
                break;
            }
            sent_bytes += size;
            kept_len += 1;
        }
    } else {
        for (snapshot.events) |event| {
            sent_bytes += try measureParsedEvent(ctx.allocator, event);
        }
    }

    // Slice `events` / `holders` down to the kept prefix when the cap
    // truncated the response. The dropped holders must be deinited so
    // their per-envelope arenas release before the original backing
    // slice is freed; the original slices themselves are then freed
    // because we replaced them with a smaller allocation.
    var events_to_render: []const std.json.Value = snapshot.events;
    var holders_to_render: []const std.json.Parsed(std.json.Value) = snapshot.holders;
    if (kept_len < snapshot.events.len) {
        for (snapshot.holders[kept_len..]) |h| h.deinit();
        if (kept_len == 0) {
            ctx.allocator.free(snapshot.events);
            ctx.allocator.free(snapshot.holders);
            events_to_render = &[_]std.json.Value{};
            holders_to_render = &[_]std.json.Parsed(std.json.Value){};
        } else {
            const new_events = try ctx.allocator.alloc(std.json.Value, kept_len);
            @memcpy(new_events, snapshot.events[0..kept_len]);
            const new_holders = try ctx.allocator.alloc(
                std.json.Parsed(std.json.Value),
                kept_len,
            );
            @memcpy(new_holders, snapshot.holders[0..kept_len]);
            ctx.allocator.free(snapshot.events);
            ctx.allocator.free(snapshot.holders);
            events_to_render = new_events;
            holders_to_render = new_holders;
        }
    }

    defer {
        for (holders_to_render) |h| h.deinit();
        ctx.allocator.free(events_to_render);
        ctx.allocator.free(holders_to_render);
    }

    // `ring_bytes` is a sibling field that only appears when the caller
    // supplied `?ring_bytes=`. `ringApproxBytes` is cheap (single mutex
    // acquisition + linear walk over up to RingCap entries) so we
    // measure it once here even on the no-DB path; the ring map
    // returns 0 when it has never been initialised.
    if (ring_bytes_present) {
        const ring_bytes = realtime.ringApproxBytes(workspace_id, user_id);
        try ctx.renderJson(.{
            .events = events_to_render,
            .since_seq = since_seq,
            .latest_seq = snapshot.latest_seq,
            .replayed = @as(usize, events_to_render.len),
            .truncated = truncated,
            .sent_bytes = sent_bytes,
            .ring_bytes = ring_bytes,
        });
        return;
    }

    try ctx.renderJson(.{
        .events = events_to_render,
        .since_seq = since_seq,
        .latest_seq = snapshot.latest_seq,
        .replayed = @as(usize, events_to_render.len),
        .truncated = truncated,
        .sent_bytes = sent_bytes,
    });
}

/// Serialise a single parsed event into a temporary buffer and return
/// the resulting byte count. The buffer is freed before return so the
/// heap stays clean. Used both for the un-truncated measurement path
/// and for incremental `?max_bytes=` accounting.
fn measureParsedEvent(allocator: std.mem.Allocator, event: std.json.Value) !usize {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(event, .{}, &buf.writer);
    return buf.written().len;
}

pub fn purgeInboxPair(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = (try ctx.getPara("user_id")) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "user_id is required" });
        return;
    };

    // Distinguish a service-account caller (X-Service-Token bypass via
    // `RequireServiceOrWorkspaceRole`) from a real workspace admin. The
    // log line is best-effort and never blocks the purge itself; the
    // JSON response is unchanged.
    const actor_kind: []const u8 = if (ctx.getAttr("service_actor") != null)
        "service_actor"
    else if (ctx.getAttr("workspace_role")) |role|
        role
    else
        "unknown";
    // Capture the actor's user id so the audit log can attribute the
    // purge back to a real account (or stay empty for anonymous service
    // tokens). The query-param `user_id` below is the *target* of the
    // purge — distinct from the caller.
    const actor_user_id = ctx.attributes.get("user_id") orelse "";
    log.info(
        "inbox purge requested by {s} for workspace_id={s} user_id={s}",
        .{ actor_kind, workspace_id, user_id },
    );

    realtime.purgePair(workspace_id, user_id);

    // Append a structured audit line so service-token purges are
    // observable out-of-band of the process log. Best-effort: failures
    // are logged inside `appendAudit` and never block the response.
    realtime.appendAudit(actor_kind, actor_user_id, "inbox.purge", workspace_id, user_id, "manual", &.{});

    try ctx.renderJson(.{
        .purged = true,
        .workspace_id = workspace_id,
        .user_id = user_id,
    });
}

pub fn exportInboxEvents(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    // Fall back to the caller's own user id when `?user_id=` is absent
    // so admins can dump their own ring without extra ceremony.
    const target_user_id = (try ctx.getPara("user_id")) orelse (getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    });

    // `format` defaults to `json` to preserve the historical wire
    // shape. Anything other than the explicit `jsonl` keyword is
    // treated as `json` so the endpoint is forgiving of typos in
    // tooling that doesn't quote its query strings.
    const format = (try ctx.getPara("format")) orelse "json";
    const use_jsonl = std.mem.eql(u8, format, "jsonl");

    // Distinguish a service-account caller from a real workspace admin
    // so the audit log can attribute the export correctly.
    const actor_kind: []const u8 = if (ctx.attributes.get("service_actor") != null)
        "service_actor"
    else if (ctx.attributes.get("workspace_role")) |role|
        role
    else
        "unknown";
    const actor_user_id = ctx.attributes.get("user_id") orelse "";

    log.info(
        "inbox export requested by {s} for workspace_id={s} user_id={s} format={s}",
        .{ actor_kind, workspace_id, target_user_id, format },
    );

    // Use `since_seq=0` because the spec is "export the ring" rather
    // than "resume from cursor". Clients that want only the tail can
    // trim the resulting array client-side, or call `listInboxSince`
    // with their cursor.
    const snapshot = realtime.replaySnapshot(
        ctx.allocator,
        workspace_id,
        target_user_id,
        0,
    );
    defer ctx.allocator.free(snapshot.envelopes);

    // Render the response body and track the on-wire byte count so
    // the audit line can correlate format + size for downstream
    // observability. The allocator-backed body is freed at the end of
    // the branch so the audit append — which happens after the body
    // is fully serialised — always sees the true byte count.
    var bytes_exported: usize = undefined;
    if (use_jsonl) {
        // NDJSON: one envelope per line, no surrounding array. We
        // allocate a single contiguous body, write each envelope
        // followed by `\n`, and emit it as raw text with the
        // `application/x-ndjson` Content-Type so streaming clients
        // can split on newlines as bytes arrive.
        try ctx.setHeader("Content-Type", "application/x-ndjson");
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(ctx.allocator);
        for (snapshot.envelopes) |env| {
            try body.appendSlice(ctx.allocator, env);
            try body.append(ctx.allocator, '\n');
        }
        bytes_exported = body.items.len;
        try ctx.renderText(body.items);
    } else {
        // JSON: serialise once so we can both measure the on-wire
        // byte count for the audit line and ship the same bytes to
        // the client. Using `renderText` + a pre-serialised body
        // avoids a second `Stringify.valueAlloc` pass inside
        // `renderJson` and lets us record the true response size.
        try ctx.setHeader("Content-Type", "application/json");
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, snapshot.envelopes, .{});
        defer ctx.allocator.free(json);
        bytes_exported = json.len;
        try ctx.renderText(json);
    }

    // Append a structured audit line. Best-effort: failures are
    // logged inside `appendAudit` and never block the response.
    var format_kv_buf: [32]u8 = undefined;
    const format_kv = std.fmt.bufPrint(&format_kv_buf, "format={s}", .{format}) catch "format=json";
    var bytes_kv_buf: [32]u8 = undefined;
    const bytes_kv = std.fmt.bufPrint(&bytes_kv_buf, "bytes_exported={d}", .{bytes_exported}) catch "bytes_exported=0";
    realtime.appendAudit(
        actor_kind,
        actor_user_id,
        "inbox.export",
        workspace_id,
        target_user_id,
        "manual",
        &[_][]const u8{ format_kv, bytes_kv },
    );
}
