//! Comment module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response) and the escape-hatch SQL
//! helpers. `service.zig` wraps this with the business logic and the
//! in-memory fallback for the no-DB smoke path.
//!
//! The `AttachmentResponse` shape lives in the attachment module
//! (not migrated yet) and is re-imported from
//! `../attachment/service.zig`. The SQL escape hatches below are
//! the only direct DB access this module needs.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const attachment = @import("../attachment/service.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// In-memory `comment` row. Mirrors the subset of columns the no-DB
/// smoke path needs; values are stored as plain strings (no
/// timestamp parsing) because the smoke path never compares them.
pub const CommentEntry = struct {
    id: []const u8,
    issue_id: []const u8,
    workspace_id: []const u8,
    author_type: []const u8,
    author_id: []const u8,
    content: []const u8,
    type: []const u8,
    parent_id: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    resolved_at: []const u8,
    resolved_by_type: []const u8,
    resolved_by_id: []const u8,
};

/// In-memory `comment_reaction` row.
pub const ReactionEntry = struct {
    id: []const u8,
    comment_id: []const u8,
    workspace_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    emoji: []const u8,
    created_at: []const u8,
};

/// API response shape for a comment. Rendered for both the DB and
/// in-memory paths. `reactions` / `attachments` are owned by the
/// caller; `reply_count` / `last_activity_at` are only populated
/// for root comments.
pub const CommentResponse = struct {
    id: []const u8,
    issue_id: []const u8,
    author_type: []const u8,
    author_id: []const u8,
    content: []const u8,
    type: []const u8,
    parent_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    resolved_at: ?[]const u8,
    resolved_by_type: ?[]const u8,
    resolved_by_id: ?[]const u8,
    reactions: []ReactionResponse,
    attachments: []attachment.AttachmentResponse,
    reply_count: ?i32,
    last_activity_at: ?[]const u8,
    content_truncated: ?bool,
};

pub const ReactionResponse = struct {
    id: []const u8,
    comment_id: []const u8,
    emoji: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    created_at: []const u8,
};

/// Request body for `POST /api/issues/:id/comments`.
pub const CreateCommentRequest = struct {
    content: []const u8,
    type: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    attachment_ids: []const []const u8 = &.{},
    suppress_agent_ids: []const []const u8 = &.{},
};

/// Request body for `PUT /api/comments/:commentId`.
pub const UpdateCommentRequest = struct {
    content: ?[]const u8 = null,
};

/// Request body for `POST /api/comments/:commentId/reactions` and
/// the matching DELETE.
pub const ReactionRequest = struct {
    emoji: []const u8,
};

/// `SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid` —
/// issue-scoped existence check. Used by the list and create paths so
/// they 404 cleanly when an issue was deleted.
pub fn issueExists(workspace_id: []const u8, issue_id: []const u8) !bool {
    const db = try deps.acquire();
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

/// Build the wide `SELECT id, issue_id, …` projection used by every
/// comment row-fetch path. Centralising the column list keeps the
/// `commentResponseFromRow` indexer in sync with the SQL.
pub const CommentRow = struct {
    id: []const u8,
    issue_id: []const u8,
    author_type: []const u8,
    author_id: []const u8,
    content: []const u8,
    type: []const u8,
    parent_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    resolved_at: ?[]const u8,
    resolved_by_type: ?[]const u8,
    resolved_by_id: ?[]const u8,
    /// Reply count column (12) — only populated for root-comment queries
    /// (`parent_id IS NULL`). Zero / 0 for plain-row queries.
    reply_count: i64,
    /// Last-activity column (13) — only populated for root-comment queries.
    last_activity_at: ?[]const u8,
};

/// Read `row` from a `comment` table projection. `reply_count_idx` /
/// `last_activity_idx` are `null` for the plain-row queries that
/// don't project the aggregate columns.
pub fn rowFromCommentTable(rs: *zfinal.ResultSet, row: usize, has_aggregates: bool) CommentRow {
    const r = &rs.rows.items[row];
    var reply_count: i64 = 0;
    var last_activity_at: ?[]const u8 = null;
    if (has_aggregates) {
        reply_count = std.fmt.parseInt(i64, r.getText(12) orelse "0", 10) catch 0;
        last_activity_at = r.getText(13);
    }
    return .{
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
        .reply_count = reply_count,
        .last_activity_at = last_activity_at,
    };
}

/// Build a `CommentResponse` from a `CommentRow`. `with_stats`
/// toggles the optional `reply_count` / `last_activity_at` fields —
/// root-comment queries pass `true`, plain row queries pass `false`.
pub fn responseFromRow(row: CommentRow, with_stats: bool, summary_truncated: ?bool) CommentResponse {
    return CommentResponse{
        .id = row.id,
        .issue_id = row.issue_id,
        .author_type = row.author_type,
        .author_id = row.author_id,
        .content = row.content,
        .type = row.type,
        .parent_id = row.parent_id,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
        .resolved_at = row.resolved_at,
        .resolved_by_type = row.resolved_by_type,
        .resolved_by_id = row.resolved_by_id,
        .reactions = &.{},
        .attachments = &.{},
        .reply_count = if (with_stats) @intCast(row.reply_count) else null,
        .last_activity_at = if (with_stats) row.last_activity_at else null,
        .content_truncated = summary_truncated,
    };
}

/// `SELECT id, comment_id, workspace_id, actor_type, actor_id, emoji, created_at
///  FROM comment_reaction WHERE comment_id = $1::uuid ORDER BY created_at ASC` —
/// load all reactions for a given comment. The output slice is
/// caller-owned (free with `allocator.free`).
pub fn fetchReactions(comment_id: []const u8) ![]ReactionResponse {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT id, comment_id, workspace_id, actor_type, actor_id, emoji, created_at " ++
            "FROM comment_reaction WHERE comment_id = $1::uuid ORDER BY created_at ASC",
        &[_]SqlParam{.{ .text = comment_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(ReactionResponse) = .empty;
    errdefer list.deinit(db.allocator);
    for (0..rs.rows.items.len) |i| {
        const r = &rs.rows.items[i];
        try list.append(db.allocator, ReactionResponse{
            .id = r.getText(0) orelse "",
            .comment_id = r.getText(1) orelse "",
            .emoji = r.getText(5) orelse "",
            .actor_type = r.getText(3) orelse "",
            .actor_id = r.getText(4) orelse "",
            .created_at = r.getText(6) orelse "",
        });
    }
    return list.toOwnedSlice(db.allocator);
}

/// Append root comments for `(issue_id, workspace_id)` to `out` with
/// reply counts and last-activity aggregates. `since` is an optional
/// lower-bound timestamp (`created_at > since`); pass `null` to read
/// all rows. Each row is appended as a 14-column projection so
/// `rowFromCommentTable` can decode it with `has_aggregates = true`.
pub fn appendRootComments(
    out: *std.ArrayList(CommentRow),
    workspace_id: []const u8,
    issue_id: []const u8,
    since: ?[]const u8,
) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
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
        try out.append(out.allocator, rowFromCommentTable(&rs, i, true));
    }
}

/// Append all comments (root + replies) for `(issue_id, workspace_id)`
/// to `out`. `since` is optional. The projection is the plain 12-column
/// list (no aggregates), so `rowFromCommentTable` decodes with
/// `has_aggregates = false`.
pub fn appendAllComments(
    out: *std.ArrayList(CommentRow),
    workspace_id: []const u8,
    issue_id: []const u8,
    since: ?[]const u8,
) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
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
        try out.append(out.allocator, rowFromCommentTable(&rs, i, false));
    }
}

/// Look up a single comment by id + workspace. Returns `null` when
/// the row is absent.
pub fn fetchCommentById(workspace_id: []const u8, comment_id: []const u8) !?CommentRow {
    const db = try deps.acquire();
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
    if (rs.rows.items.len == 0) return null;
    return rowFromCommentTable(&rs, 0, false);
}

/// `INSERT INTO comment (…) VALUES (…) RETURNING …` — create a new
/// comment row. `parent_id` may be empty (root comment) and is
/// converted to `NULL` in SQL via `NULLIF($7, '')::uuid`.
pub fn insertComment(
    workspace_id: []const u8,
    issue_id: []const u8,
    user_id: []const u8,
    content: []const u8,
    comment_type: []const u8,
    parent_id: []const u8,
) !CommentRow {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
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
    if (rs.rows.items.len == 0) return error.InsertFailed;
    return rowFromCommentTable(&rs, 0, false);
}

/// `SELECT 1 FROM comment WHERE id = $1::uuid AND issue_id = $2::uuid
///  AND workspace_id = $3::uuid` — parent-comment existence check for
/// the create path.
pub fn parentCommentExists(workspace_id: []const u8, issue_id: []const u8, parent_id: []const u8) !bool {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT 1 FROM comment WHERE id = $1::uuid AND issue_id = $2::uuid AND workspace_id = $3::uuid",
        &[_]SqlParam{
            .{ .text = parent_id },
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    );
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT author_type, author_id FROM comment WHERE id = $1::uuid
///  AND workspace_id = $2::uuid` — load just the author fields so the
/// update / delete paths can validate ownership.
pub fn fetchAuthorForUpdate(workspace_id: []const u8, comment_id: []const u8) !?struct { author_type: []const u8, author_id: []const u8 } {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT author_type, author_id FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = comment_id },
            .{ .text = workspace_id },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return .{
        .author_type = rs.rows.items[0].getText(0) orelse "",
        .author_id = rs.rows.items[0].getText(1) orelse "",
    };
}

/// `UPDATE comment SET content = COALESCE(NULLIF($3, ''), content),
///  updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid
///  RETURNING …` — update the comment body in place.
pub fn updateCommentBody(
    workspace_id: []const u8,
    comment_id: []const u8,
    content: []const u8,
) !?CommentRow {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
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
    if (rs.rows.items.len == 0) return null;
    return rowFromCommentTable(&rs, 0, false);
}

/// `DELETE FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid` —
/// hard delete a comment row.
pub fn deleteCommentRow(workspace_id: []const u8, comment_id: []const u8) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    try db.execParams(
        "DELETE FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = comment_id },
            .{ .text = workspace_id },
        },
    );
}

/// `UPDATE comment SET resolved_at = now(), resolved_by_type = 'member',
///  resolved_by_id = $3::uuid WHERE id = $1::uuid AND workspace_id = $2::uuid
///  RETURNING …` — mark a comment resolved by `user_id`.
pub fn resolveCommentRow(workspace_id: []const u8, comment_id: []const u8, user_id: []const u8) !?CommentRow {
    const db = try deps.acquire();
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
    if (rs.rows.items.len == 0) return null;
    return rowFromCommentTable(&rs, 0, false);
}

/// `UPDATE comment SET resolved_at = NULL, resolved_by_type = NULL,
///  resolved_by_id = NULL WHERE id = $1::uuid AND workspace_id = $2::uuid
///  RETURNING …` — un-resolve a comment.
pub fn unresolveCommentRow(workspace_id: []const u8, comment_id: []const u8) !?CommentRow {
    const db = try deps.acquire();
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
    if (rs.rows.items.len == 0) return null;
    return rowFromCommentTable(&rs, 0, false);
}

/// `SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid` —
/// existence check used by the reaction add / remove paths.
pub fn commentExists(workspace_id: []const u8, comment_id: []const u8) !bool {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = comment_id },
            .{ .text = workspace_id },
        },
    );
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `INSERT INTO comment_reaction (…) VALUES (…) ON CONFLICT (…) DO UPDATE
///  SET created_at = comment_reaction.created_at RETURNING …` — add
/// (or no-op) a reaction row.
pub fn insertReaction(
    workspace_id: []const u8,
    comment_id: []const u8,
    user_id: []const u8,
    emoji: []const u8,
) !?ReactionResponse {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
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
    if (rs.rows.items.len == 0) return null;
    const r = &rs.rows.items[0];
    return ReactionResponse{
        .id = r.getText(0) orelse "",
        .comment_id = r.getText(1) orelse "",
        .emoji = r.getText(5) orelse "",
        .actor_type = r.getText(3) orelse "",
        .actor_id = r.getText(4) orelse "",
        .created_at = r.getText(6) orelse "",
    };
}

/// `DELETE FROM comment_reaction WHERE comment_id = $1::uuid AND
///  actor_type = $2 AND actor_id = $3::uuid AND emoji = $4` — remove
/// a single reaction row.
pub fn deleteReaction(
    comment_id: []const u8,
    user_id: []const u8,
    emoji: []const u8,
) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    try db.execParams(
        "DELETE FROM comment_reaction WHERE comment_id = $1::uuid AND actor_type = $2 AND actor_id = $3::uuid AND emoji = $4",
        &[_]SqlParam{
            .{ .text = comment_id },
            .{ .text = "member" },
            .{ .text = user_id },
            .{ .text = emoji },
        },
    );
}
