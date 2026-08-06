//! Attachment module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape, request/response DTOs) and
//! the escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic and the in-memory attachment store.
//!
//! The `attachment` table uses UUID PKs with TIMESTAMPTZ columns
//! that the ORM can't model cleanly, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`. The in-memory fallback
//! uses the `AttachmentEntry` struct defined here so the no-DB
//! smoke-test path stays deterministic.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// Page allocator used by the in-memory store. Matches the
/// per-process lifetime of the attachment registry.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// In-memory `attachment` row.
pub const AttachmentEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    issue_id: []const u8,
    comment_id: []const u8,
    chat_session_id: []const u8,
    chat_message_id: []const u8,
    uploader_type: []const u8,
    uploader_id: []const u8,
    filename: []const u8,
    url: []const u8,
    content_type: []const u8,
    size_bytes: i64,
    created_at: []const u8,
};

/// Public `attachment` response — re-exported from `service.zig` for
/// cross-module consumers (`comment` reads `listForComment` /
/// `setCommentId` and embeds `AttachmentResponse` in its own
/// payloads).
pub const AttachmentResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    issue_id: ?[]const u8,
    comment_id: ?[]const u8,
    chat_session_id: ?[]const u8,
    chat_message_id: ?[]const u8,
    uploader_type: []const u8,
    uploader_id: []const u8,
    filename: []const u8,
    url: []const u8,
    download_url: []const u8,
    markdown_url: []const u8,
    content_type: []const u8,
    size_bytes: i64,
    created_at: []const u8,
};

/// Sidecar `.meta.json` schema — stored next to the upload file in
/// the local uploads directory so `serveUploads` can resolve the
/// workspace without a DB round-trip.
pub const LocalMeta = struct {
    workspace_id: []const u8 = "",
    filename: []const u8,
    content_type: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// constants
// ──────────────────────────────────────────────────────────────────────

pub const upload_dir = "uploads";
pub const max_upload_size = 100 * 1024 * 1024;
pub const max_preview_size = 2 * 1024 * 1024;
pub const meta_suffix = ".meta.json";

// ──────────────────────────────────────────────────────────────────────
// row / entry → response shape
// ──────────────────────────────────────────────────────────────────────

pub fn attachmentResponseFromEntry(entry: AttachmentEntry) AttachmentResponse {
    return AttachmentResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .issue_id = if (entry.issue_id.len > 0) entry.issue_id else null,
        .comment_id = if (entry.comment_id.len > 0) entry.comment_id else null,
        .chat_session_id = if (entry.chat_session_id.len > 0) entry.chat_session_id else null,
        .chat_message_id = if (entry.chat_message_id.len > 0) entry.chat_message_id else null,
        .uploader_type = entry.uploader_type,
        .uploader_id = entry.uploader_id,
        .filename = entry.filename,
        .url = entry.url,
        .download_url = entry.url,
        .markdown_url = entry.url,
        .content_type = entry.content_type,
        .size_bytes = entry.size_bytes,
        .created_at = entry.created_at,
    };
}

pub fn attachmentResponseFromRow(rs: *zfinal.ResultSet, row: usize) AttachmentResponse {
    const r = &rs.rows.items[row];
    return AttachmentResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .issue_id = r.getText(2),
        .comment_id = r.getText(3),
        .chat_session_id = r.getText(4),
        .chat_message_id = r.getText(5),
        .uploader_type = r.getText(6) orelse "",
        .uploader_id = r.getText(7) orelse "",
        .filename = r.getText(8) orelse "",
        .url = r.getText(9) orelse "",
        .download_url = r.getText(9) orelse "",
        .markdown_url = r.getText(9) orelse "",
        .content_type = r.getText(10) orelse "",
        .size_bytes = @intCast(std.fmt.parseInt(i64, r.getText(11) orelse "0", 10) catch 0),
        .created_at = r.getText(12) orelse "",
    };
}

// ──────────────────────────────────────────────────────────────────────
// escape-hatch SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// `SELECT 1 FROM member WHERE workspace_id = $1::uuid AND user_id = $2::uuid`.
/// Returns `true` in no-DB mode (the smoke-test path trusts the
/// caller — there's no member table to check).
pub fn isWorkspaceMember(user_id: []const u8, workspace_id: []const u8) bool {
    const d = borrowDb() orelse return true; // no-DB fallback: allow
    defer deps.releaseBack(d);
    var rs = d.queryParams(
        "SELECT 1 FROM member WHERE workspace_id = $1::uuid AND user_id = $2::uuid",
        &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid`.
pub fn issueExistsInWorkspace(issue_id: []const u8, workspace_id: []const u8) bool {
    const d = borrowDb() orelse return true;
    defer deps.releaseBack(d);
    var rs = d.queryParams(
        "SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{ .{ .text = issue_id }, .{ .text = workspace_id } },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid`.
pub fn commentExistsInWorkspace(comment_id: []const u8, workspace_id: []const u8) bool {
    const d = borrowDb() orelse return true;
    defer deps.releaseBack(d);
    var rs = d.queryParams(
        "SELECT 1 FROM comment WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{ .{ .text = comment_id }, .{ .text = workspace_id } },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT 1 FROM chat_session WHERE id = $1::uuid AND workspace_id = $2::uuid
/// AND created_by = $3::uuid`.
pub fn chatSessionForUser(session_id: []const u8, user_id: []const u8, workspace_id: []const u8) bool {
    const d = borrowDb() orelse return true;
    defer deps.releaseBack(d);
    var rs = d.queryParams(
        "SELECT 1 FROM chat_session WHERE id = $1::uuid AND workspace_id = $2::uuid AND created_by = $3::uuid",
        &[_]SqlParam{
            .{ .text = session_id },
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// Pair of `uploader_type` / `uploader_id` strings — produced by
/// `resolveActor` and consumed by the upload SQL.
pub const ResolveActor = struct {
    uploader_type: []const u8,
    uploader_id: []const u8,
};

/// Maps a `user_id` to the `(uploader_type, uploader_id)` pair that
/// the `attachment` table expects. For now every authenticated
/// uploader is recorded as a `"member"`.
pub fn resolveActor(user_id: []const u8) ResolveActor {
    return .{ .uploader_type = "member", .uploader_id = user_id };
}

/// Accept either a 32-char hex UUID or a standard 36-char hyphenated
/// UUID. Returns a borrowed slice for the 32-char form and a
/// `page_allocator`-backed slice for the 36-char form. Returns `null`
/// when the input is neither shape.
pub fn uuidFromString(s: []const u8) ?[]const u8 {
    if (s.len == 32) {
        for (s) |c| {
            if (!std.ascii.isHex(c)) return null;
        }
        return s;
    }
    if (s.len == 36) {
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        for (s) |c| {
            if (c == '-') continue;
            if (!std.ascii.isHex(c)) return null;
            buf[i] = c;
            i += 1;
        }
        return std.heap.page_allocator.dupe(u8, &buf) catch return null;
    }
    return null;
}
