//! Comment module — business logic.
//!
//! Owns the per-process state (`mem_comments`, `mem_reactions`) and
//! the in-memory fallback for every comment route. The
//! `attachment` module's helpers (`setCommentId`, `listForComment`,
//! `AttachmentResponse`) are imported from the migrated
//! `../attachment/service.zig`.
//!
//! All public functions take `*zfinal.Context` and follow the
//! 1-handler-per-route shape; the corresponding `handler.zig` is a
//! thin delegate. SQL helpers and data structs live in `model.zig`.

const std = @import("std");
const response = @import("../../common/response.zig");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const attachment = @import("../attachment/service.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");
const realtime = @import("../realtime/service.zig");

const log = std.log.scoped(.comment_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_comments: ?std.StringHashMap(model.CommentEntry) = null;
var mem_reactions: ?std.StringHashMap(model.ReactionEntry) = null;

/// Fan out a workspace realtime event for a comment mutation.
fn publishCommentEvent(ctx: *zfinal.Context, workspace_id: []const u8, event_type: []const u8, comment_id: []const u8, issue_id: []const u8) void {
    const user_id = common_ctx.getUserId(ctx) orelse "";
    const text = std.fmt.allocPrint(
        ctx.allocator,
        "{{\"type\":\"{s}\",\"workspace_id\":\"{s}\",\"comment_id\":\"{s}\",\"issue_id\":\"{s}\",\"actor_type\":\"member\",\"actor_id\":\"{s}\"}}",
        .{ event_type, workspace_id, comment_id, issue_id, user_id },
    ) catch return;
    defer ctx.allocator.free(text);
    realtime.publishEvent(workspace_id, text);
}

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_comments == null) {
        mem_comments = std.StringHashMap(model.CommentEntry).init(memAlloc());
        mem_reactions = std.StringHashMap(model.ReactionEntry).init(memAlloc());
    }
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

fn looksLikeUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        const c = s[i];
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isAlphanumeric(c)) {
            return false;
        }
    }
    return true;
}

fn commentResponseFromEntry(entry: model.CommentEntry, with_stats: bool, reply_count: i32, last_activity_at: ?[]const u8, summary_truncated: ?bool) model.CommentResponse {
    return model.CommentResponse{
        .id = entry.id,
        .issue_id = entry.issue_id,
        .author_type = entry.author_type,
        .author_id = entry.author_id,
        .content = entry.content,
        .type = entry.type,
        .parent_id = if (entry.parent_id.len > 0) entry.parent_id else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .resolved_at = if (entry.resolved_at.len > 0) entry.resolved_at else null,
        .resolved_by_type = if (entry.resolved_by_type.len > 0) entry.resolved_by_type else null,
        .resolved_by_id = if (entry.resolved_by_id.len > 0) entry.resolved_by_id else null,
        .reactions = &.{},
        .attachments = &.{},
        .reply_count = if (with_stats) reply_count else null,
        .last_activity_at = last_activity_at,
        .content_truncated = summary_truncated,
    };
}

fn commentResponseFromRow(rs: *zfinal.ResultSet, row: usize, with_stats: bool, reply_count: i32, last_activity_at: ?[]const u8, summary_truncated: ?bool) model.CommentResponse {
    const r = &rs.rows.items[row];
    return model.CommentResponse{
        .id = r.getText(0) orelse "",
        .issue_id = r.getText(1) orelse "",
        .author_type = r.getText(2) orelse "",
        .author_id = r.getText(3) orelse "",
        .content = r.getText(4) orelse "",
        .type = r.getText(5) orelse "",
        .parent_id = r.getText(6),
        .created_at = r.getText(7) orelse "",
        .updated_at = r.getText(8) orelse "",
        .resolved_at = r.getText(9),
        .resolved_by_type = r.getText(10),
        .resolved_by_id = r.getText(11),
        .reactions = &.{},
        .attachments = &.{},
        .reply_count = if (with_stats) reply_count else null,
        .last_activity_at = last_activity_at,
        .content_truncated = summary_truncated,
    };
}

fn reactionResponseFromEntry(entry: model.ReactionEntry) model.ReactionResponse {
    return model.ReactionResponse{
        .id = entry.id,
        .comment_id = entry.comment_id,
        .emoji = entry.emoji,
        .actor_type = entry.actor_type,
        .actor_id = entry.actor_id,
        .created_at = entry.created_at,
    };
}

fn reactionResponseFromRow(rs: *zfinal.ResultSet, row: usize) model.ReactionResponse {
    const r = &rs.rows.items[row];
    return model.ReactionResponse{
        .id = r.getText(0) orelse "",
        .comment_id = r.getText(1) orelse "",
        .emoji = r.getText(5) orelse "",
        .actor_type = r.getText(3) orelse "",
        .actor_id = r.getText(4) orelse "",
        .created_at = r.getText(6) orelse "",
    };
}

fn loadReactions(allocator: std.mem.Allocator, comment_id: []const u8) ![]model.ReactionResponse {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, comment_id, workspace_id, actor_type, actor_id, emoji, created_at " ++
                "FROM comment_reaction WHERE comment_id = $1::uuid ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = comment_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.ReactionResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, reactionResponseFromRow(&rs, i));
        }
        return list.toOwnedSlice(allocator);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.ReactionResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_reactions.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.comment_id, comment_id)) continue;
            try list.append(allocator, reactionResponseFromEntry(entry));
        }
        return list.toOwnedSlice(allocator);
    }
}

fn loadAttachments(allocator: std.mem.Allocator, workspace_id: []const u8, comment_id: []const u8) ![]attachment.AttachmentResponse {
    var list: std.ArrayList(attachment.AttachmentResponse) = .empty;
    defer list.deinit(allocator);
    try attachment.listForComment(allocator, workspace_id, comment_id, &list);
    return list.toOwnedSlice(allocator);
}

fn summarizeContent(allocator: std.mem.Allocator, content: []const u8, truncated: ?bool) !struct { content: []const u8, was_truncated: bool } {
    if (truncated != null and truncated.? == false) {
        return .{ .content = content, .was_truncated = false };
    }
    const budget = 200;
    var iter = std.unicode.Utf8Iterator{ .bytes = content, .i = 0 };
    var count: usize = 0;
    var end_byte: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        _ = cp;
        if (count == budget) {
            const suffix = try std.fmt.allocPrint(allocator, "{s}…", .{content[0..end_byte]});
            return .{ .content = suffix, .was_truncated = true };
        }
        end_byte = iter.i;
        count += 1;
    }
    return .{ .content = content, .was_truncated = false };
}

fn issueExists(workspace_id: []const u8, issue_id: []const u8) !bool {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = issue_id },
                .{ .text = workspace_id },
            },
        );
        defer rs.deinit();
        return rs.rows.items.len > 0;
    }
    return true;
}

// ──────────────────────────────────────────────────────────────────────
// HTTP handlers
// ──────────────────────────────────────────────────────────────────────

pub fn listComments(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const issue_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };

    const since = ctx.getPara("since") catch null;
    const roots_only_str = ctx.getPara("roots_only") catch null;
    const summary_str = ctx.getPara("summary") catch null;
    const roots_only = std.mem.eql(u8, roots_only_str orelse "false", "true");
    const summary = std.mem.eql(u8, summary_str orelse "false", "true");

    if (!try issueExists(workspace_id, issue_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "issue not found" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var list: std.ArrayList(model.CommentResponse) = .empty;
        defer list.deinit(allocator);

        if (roots_only) {
            var rs = if (since) |s| try db.queryParams(
                "SELECT id, issue_id, author_type, author_id, content, type, parent_id, " ++
                    "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id, " ++
                    "(SELECT COUNT(*) FROM comment r WHERE r.parent_id = comment.id) AS reply_count, " ++
                    "(SELECT MAX(created_at) FROM comment r WHERE r.parent_id = comment.id) AS last_activity_at " ++
                    "FROM comment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid AND parent_id IS NULL " ++
                    "AND created_at > $3::timestamptz ORDER BY created_at ASC LIMIT 2000",
                &[_]SqlParam{
                    .{ .text = issue_id },
                    .{ .text = workspace_id },
                    .{ .text = s },
                },
            ) else try db.queryParams(
                "SELECT id, issue_id, author_type, author_id, content, type, parent_id, " ++
                    "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id, " ++
                    "(SELECT COUNT(*) FROM comment r WHERE r.parent_id = comment.id) AS reply_count, " ++
                    "(SELECT MAX(created_at) FROM comment r WHERE r.parent_id = comment.id) AS last_activity_at " ++
                    "FROM comment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid AND parent_id IS NULL " ++
                    "ORDER BY created_at ASC LIMIT 2000",
                &[_]SqlParam{
                    .{ .text = issue_id },
                    .{ .text = workspace_id },
                },
            );
            defer rs.deinit();
            for (0..rs.rows.items.len) |i| {
                const r = &rs.rows.items[i];
                const raw = r.getText(4) orelse "";
                const reply_count: i32 = @intCast(std.fmt.parseInt(i64, r.getText(12) orelse "0", 10) catch 0);
                const last_activity_at = r.getText(13);
                var summary_holder: ?[]const u8 = null;
                defer if (summary_holder) |s| allocator.free(s);
                var truncated: ?bool = null;
                const content = if (summary) b: {
                    const sr = try summarizeContent(allocator, raw, null);
                    summary_holder = sr.content;
                    truncated = sr.was_truncated;
                    break :b sr.content;
                } else raw;
                try list.append(allocator, commentResponseFromRow(&rs, i, true, reply_count, last_activity_at, truncated));
                list.items[list.items.len - 1].content = content;
                const comment_id = list.items[list.items.len - 1].id;
                list.items[list.items.len - 1].reactions = try loadReactions(allocator, comment_id);
                list.items[list.items.len - 1].attachments = try loadAttachments(allocator, workspace_id, comment_id);
            }
        } else {
            var rs = if (since) |s| try db.queryParams(
                "SELECT id, issue_id, author_type, author_id, content, type, parent_id, " ++
                    "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id " ++
                    "FROM comment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid " ++
                    "AND created_at > $3::timestamptz ORDER BY created_at ASC LIMIT 2000",
                &[_]SqlParam{
                    .{ .text = issue_id },
                    .{ .text = workspace_id },
                    .{ .text = s },
                },
            ) else try db.queryParams(
                "SELECT id, issue_id, author_type, author_id, content, type, parent_id, " ++
                    "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id " ++
                    "FROM comment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid " ++
                    "ORDER BY created_at ASC LIMIT 2000",
                &[_]SqlParam{
                    .{ .text = issue_id },
                    .{ .text = workspace_id },
                },
            );
            defer rs.deinit();
            for (0..rs.rows.items.len) |i| {
                const r = &rs.rows.items[i];
                const raw = r.getText(4) orelse "";
                var summary_holder: ?[]const u8 = null;
                defer if (summary_holder) |s| allocator.free(s);
                var truncated: ?bool = null;
                const content = if (summary) b: {
                    const sr = try summarizeContent(allocator, raw, null);
                    summary_holder = sr.content;
                    truncated = sr.was_truncated;
                    break :b sr.content;
                } else raw;
                try list.append(allocator, commentResponseFromRow(&rs, i, false, 0, null, truncated));
                list.items[list.items.len - 1].content = content;
                const comment_id = list.items[list.items.len - 1].id;
                list.items[list.items.len - 1].reactions = try loadReactions(allocator, comment_id);
                list.items[list.items.len - 1].attachments = try loadAttachments(allocator, workspace_id, comment_id);
            }
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.CommentResponse) = .empty;
        defer list.deinit(allocator);

        var it = mem_comments.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.issue_id, issue_id)) continue;
            if (roots_only and entry.parent_id.len > 0) continue;

            var reply_count: i32 = 0;
            var last_activity_at: ?[]const u8 = null;
            if (roots_only) {
                var it2 = mem_comments.?.iterator();
                while (it2.next()) |e2| {
                    const child = e2.value_ptr.*;
                    if (std.mem.eql(u8, child.parent_id, entry.id)) {
                        reply_count += 1;
                        if (last_activity_at == null or std.mem.order(u8, child.created_at, last_activity_at.?) == .gt) {
                            last_activity_at = child.created_at;
                        }
                    }
                }
            }

            const raw = entry.content;
            var summary_holder: ?[]const u8 = null;
            defer if (summary_holder) |s| allocator.free(s);
            var truncated: ?bool = null;
            const content = if (summary) b: {
                const sr = try summarizeContent(allocator, raw, null);
                summary_holder = sr.content;
                truncated = sr.was_truncated;
                break :b sr.content;
            } else raw;

            try list.append(allocator, commentResponseFromEntry(entry, roots_only, reply_count, last_activity_at, truncated));
            list.items[list.items.len - 1].content = content;

            var reactions: std.ArrayList(model.ReactionResponse) = .empty;
            defer reactions.deinit(allocator);
            var rit = mem_reactions.?.iterator();
            while (rit.next()) |re| {
                const rx = re.value_ptr.*;
                if (std.mem.eql(u8, rx.comment_id, entry.id)) {
                    try reactions.append(allocator, reactionResponseFromEntry(rx));
                }
            }
            list.items[list.items.len - 1].reactions = try reactions.toOwnedSlice(allocator);

            const comment_id = list.items[list.items.len - 1].id;
            list.items[list.items.len - 1].attachments = try loadAttachments(allocator, workspace_id, comment_id);
        }
        try ctx.renderJson(list.items);
    }
}

pub fn getComment(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, issue_id, author_type, author_id, content, type, parent_id, " ++
                "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id " ++
                "FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        var resp = commentResponseFromRow(&rs, 0, false, 0, null, null);
        resp.reactions = try loadReactions(allocator, resp.id);
        resp.attachments = try loadAttachments(allocator, workspace_id, resp.id);
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_comments.?.get(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        var resp = commentResponseFromEntry(entry, false, 0, null, null);
        resp.reactions = try loadReactions(allocator, resp.id);
        resp.attachments = try loadAttachments(allocator, workspace_id, resp.id);
        try ctx.renderJson(resp);
    }
}

pub fn createComment(ctx: *zfinal.Context) !void {
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
    const issue_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateCommentRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const content = std.mem.trim(u8, req.content, &std.ascii.whitespace);
    if (content.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "content is required" });
        return;
    }
    const comment_type = req.type orelse "comment";
    const parent_id = req.parent_id orelse "";

    if (parent_id.len > 0 and !looksLikeUuid(parent_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid parent_id" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var issue_check = try db.queryParams(
            "SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = issue_id },
                .{ .text = workspace_id },
            },
        );
        defer issue_check.deinit();
        if (issue_check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "issue not found" });
            return;
        }

        if (parent_id.len > 0) {
            var parent_check = try db.queryParams(
                "SELECT 1 FROM comment WHERE id = $1::uuid AND issue_id = $2::uuid AND workspace_id = $3::uuid",
                &[_]SqlParam{
                    .{ .text = parent_id },
                    .{ .text = issue_id },
                    .{ .text = workspace_id },
                },
            );
            defer parent_check.deinit();
            if (parent_check.rows.items.len == 0) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid parent comment" });
                return;
            }
        }

        var rs = try db.queryParams(
            "INSERT INTO comment (issue_id, workspace_id, author_type, author_id, content, type, parent_id) " ++
                "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5, $6, NULLIF($7, '')::uuid) " ++
                "RETURNING id, issue_id, author_type, author_id, content, type, parent_id, " ++
                "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id",
            &[_]SqlParam{
                .{ .text = issue_id },
                .{ .text = workspace_id },
                .{ .text = "member" },
                .{ .text = user_id },
                .{ .text = content },
                .{ .text = comment_type },
                .{ .text = parent_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create comment" });
            return;
        }
        const comment_id = rs.rows.items[0].getText(0) orelse "";
        for (req.attachment_ids) |aid| {
            try attachment.setCommentId(aid, comment_id, workspace_id, issue_id);
        }
        var resp = commentResponseFromRow(&rs, 0, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        publishCommentEvent(ctx, workspace_id, "comment:created", comment_id, issue_id);
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        if (parent_id.len > 0) {
            const parent = mem_comments.?.get(parent_id) orelse {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid parent comment" });
                return;
            };
            if (!std.mem.eql(u8, parent.issue_id, issue_id) or !std.mem.eql(u8, parent.workspace_id, workspace_id)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid parent comment" });
                return;
            }
        }

        const id = try generateId(allocator, content);
        const now = try nowString();
        const entry = model.CommentEntry{
            .id = try memDup(id),
            .issue_id = try memDup(issue_id),
            .workspace_id = try memDup(workspace_id),
            .author_type = try memDup("member"),
            .author_id = try memDup(user_id),
            .content = try memDup(content),
            .type = try memDup(comment_type),
            .parent_id = try memDup(parent_id),
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
            .resolved_at = try memDup(""),
            .resolved_by_type = try memDup(""),
            .resolved_by_id = try memDup(""),
        };
        try mem_comments.?.put(entry.id, entry);
        for (req.attachment_ids) |aid| {
            try attachment.setCommentId(aid, entry.id, workspace_id, issue_id);
        }
        var resp = commentResponseFromEntry(entry, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, entry.id);
        publishCommentEvent(ctx, workspace_id, "comment:created", entry.id, issue_id);
        ctx.res_status = .created;
        try ctx.renderJson(resp);
    }
}

pub fn updateComment(ctx: *zfinal.Context) !void {
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
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateCommentRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const content = if (req.content) |c| std.mem.trim(u8, c, &std.ascii.whitespace) else "";
    if (req.content != null and content.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "content is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var check = try db.queryParams(
            "SELECT author_type, author_id, issue_id FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        const author_type = check.rows.items[0].getText(0) orelse "";
        const author_id = check.rows.items[0].getText(1) orelse "";
        if (!std.mem.eql(u8, author_type, "member") or !std.mem.eql(u8, author_id, user_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to update this comment" });
            return;
        }

        var rs = try db.queryParams(
            "UPDATE comment SET content = COALESCE(NULLIF($3, ''), content), updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "RETURNING id, issue_id, author_type, author_id, content, type, parent_id, " ++
                "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
                .{ .text = content },
            },
        );
        defer rs.deinit();
        var resp = commentResponseFromRow(&rs, 0, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        publishCommentEvent(ctx, workspace_id, "comment:updated", comment_id, rs.rows.items[0].getText(1) orelse "");
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_comments.?.getPtr(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        if (!std.mem.eql(u8, entry_ptr.author_type, "member") or !std.mem.eql(u8, entry_ptr.author_id, user_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to update this comment" });
            return;
        }
        if (req.content) |_| {
            entry_ptr.content = try memDup(content);
        }
        entry_ptr.updated_at = try nowString();
        var resp = commentResponseFromEntry(entry_ptr.*, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        try ctx.renderJson(resp);
    }
}

pub fn deleteComment(ctx: *zfinal.Context) !void {
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
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var check = try db.queryParams(
            "SELECT author_type, author_id FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        const author_type = check.rows.items[0].getText(0) orelse "";
        const author_id = check.rows.items[0].getText(1) orelse "";
        const del_issue_id = check.rows.items[0].getText(2) orelse "";
        if (!std.mem.eql(u8, author_type, "member") or !std.mem.eql(u8, author_id, user_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to delete this comment" });
            return;
        }

        try db.execParams(
            "DELETE FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        publishCommentEvent(ctx, workspace_id, "comment:deleted", comment_id, del_issue_id);
        try response.okNoContent(ctx);
    return;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_comments.?.get(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        if (!std.mem.eql(u8, entry.author_type, "member") or !std.mem.eql(u8, entry.author_id, user_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to delete this comment" });
            return;
        }
        _ = mem_comments.?.fetchRemove(comment_id);
        publishCommentEvent(ctx, workspace_id, "comment:deleted", comment_id, entry.issue_id);
        try response.okNoContent(ctx);
    return;
    }
}

pub fn resolveComment(ctx: *zfinal.Context) !void {
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
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "UPDATE comment SET resolved_at = now(), resolved_by_type = 'member', resolved_by_id = $3::uuid " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "RETURNING id, issue_id, author_type, author_id, content, type, parent_id, " ++
                "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        var resp = commentResponseFromRow(&rs, 0, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        publishCommentEvent(ctx, workspace_id, "comment:resolved", comment_id, rs.rows.items[0].getText(1) orelse "");
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_comments.?.getPtr(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        const now = try nowString();
        entry_ptr.resolved_at = try memDup(now);
        entry_ptr.resolved_by_type = try memDup("member");
        entry_ptr.resolved_by_id = try memDup(user_id);
        var resp = commentResponseFromEntry(entry_ptr.*, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        try ctx.renderJson(resp);
    }
}

pub fn unresolveComment(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "UPDATE comment SET resolved_at = NULL, resolved_by_type = NULL, resolved_by_id = NULL " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "RETURNING id, issue_id, author_type, author_id, content, type, parent_id, " ++
                "created_at, updated_at, resolved_at, resolved_by_type, resolved_by_id",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        var resp = commentResponseFromRow(&rs, 0, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        publishCommentEvent(ctx, workspace_id, "comment:unresolved", comment_id, rs.rows.items[0].getText(1) orelse "");
        try ctx.renderJson(resp);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_comments.?.getPtr(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }
        entry_ptr.resolved_at = try memDup("");
        entry_ptr.resolved_by_type = try memDup("");
        entry_ptr.resolved_by_id = try memDup("");
        var resp = commentResponseFromEntry(entry_ptr.*, false, 0, null, null);
        resp.attachments = try loadAttachments(allocator, workspace_id, comment_id);
        try ctx.renderJson(resp);
    }
}

pub fn previewCommentTriggers(ctx: *zfinal.Context) !void {
    _ = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    _ = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };
    try ctx.renderJson(.{ .triggers = &[_]struct {}{} });
}

pub fn addReaction(ctx: *zfinal.Context) !void {
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
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.ReactionRequest);
    defer parsed.deinit();
    const req = parsed.value;
    const emoji = std.mem.trim(u8, req.emoji, &std.ascii.whitespace);
    if (emoji.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "emoji is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var check = try db.queryParams(
            "SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }

        var rs = try db.queryParams(
            "INSERT INTO comment_reaction (comment_id, workspace_id, actor_type, actor_id, emoji) " ++
                "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5) " ++
                "ON CONFLICT (comment_id, actor_type, actor_id, emoji) DO UPDATE SET created_at = comment_reaction.created_at " ++
                "RETURNING id, comment_id, workspace_id, actor_type, actor_id, emoji, created_at",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
                .{ .text = "member" },
                .{ .text = user_id },
                .{ .text = emoji },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to add reaction" });
            return;
        }
        ctx.res_status = .created;
        try ctx.renderJson(reactionResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const comment = mem_comments.?.get(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, comment.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }

        const now = try nowString();
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ comment_id, user_id, emoji });
        defer allocator.free(key);

        const id = try generateId(allocator, key);
        // `key` was allocated with the request allocator and would
        // be freed when the handler returns. The hashmap stores it
        // as the lookup key, so memDup it to stable memory.
        const stable_key = try memDup(key);
        const entry = model.ReactionEntry{
            .id = try memDup(id),
            .comment_id = try memDup(comment_id),
            .workspace_id = try memDup(workspace_id),
            .actor_type = try memDup("member"),
            .actor_id = try memDup(user_id),
            .emoji = try memDup(emoji),
            .created_at = try memDup(now),
        };
        try mem_reactions.?.put(stable_key, entry);
        ctx.res_status = .created;
        try ctx.renderJson(reactionResponseFromEntry(entry));
    }
}

pub fn removeReaction(ctx: *zfinal.Context) !void {
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
    const comment_id = ctx.getPathParam("commentId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "comment_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.ReactionRequest);
    defer parsed.deinit();
    const req = parsed.value;
    const emoji = std.mem.trim(u8, req.emoji, &std.ascii.whitespace);
    if (emoji.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "emoji is required" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var check = try db.queryParams(
            "SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = workspace_id },
            },
        );
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }

        try model.deleteReaction(comment_id, user_id, emoji);
        try response.okNoContent(ctx);
    return;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const comment = mem_comments.?.get(comment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        };
        if (!std.mem.eql(u8, comment.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "comment not found" });
            return;
        }

        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ comment_id, user_id, emoji });
        defer allocator.free(key);
        _ = mem_reactions.?.fetchRemove(key);
        try response.okNoContent(ctx);
    return;
    }
}
