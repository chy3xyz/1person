//! Chat module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shapes + API response shapes) and
//! the escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic. The chat tables (`chat_session`, `chat_message`,
//! `agent_task_queue`) use UUID PKs with TIMESTAMPTZ/JSONB-shaped
//! columns that the ORM can't model, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`. The in-memory fallback
//! uses the `ChatSessionEntry` / `ChatMessageEntry` / `ChatTaskEntry`
//! structs defined here so the smoke-test path is exercised when the
//! DB is unconfigured.

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

/// In-memory `chat_task_queue` row.
pub const ChatTaskEntry = struct {
    id: []const u8,
    chat_session_id: []const u8,
    workspace_id: []const u8,
    creator_id: []const u8,
    status: []const u8,
    type: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `chat_session` row.
pub const ChatSessionEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    agent_id: []const u8,
    creator_id: []const u8,
    title: []const u8,
    status: []const u8,
    has_unread: bool,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `chat_message` row.
pub const ChatMessageEntry = struct {
    id: []const u8,
    chat_session_id: []const u8,
    role: []const u8,
    content: []const u8,
    task_id: []const u8,
    created_at: []const u8,
    failure_reason: []const u8,
    elapsed_ms: i64,
};

/// Response shape for a single `chat_session` row.
pub const ChatSessionResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    agent_id: []const u8,
    creator_id: []const u8,
    title: []const u8,
    status: []const u8,
    has_unread: bool,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Response shape for a single `chat_message` row.
pub const ChatMessageResponse = struct {
    id: []const u8,
    chat_session_id: []const u8,
    role: []const u8,
    content: []const u8,
    task_id: ?[]const u8,
    created_at: []const u8,
    failure_reason: ?[]const u8,
    elapsed_ms: ?i64,
    attachments: []AttachmentResponse,
};

/// Embedded attachment reference (always empty in the current API
/// surface; the column is included so clients can rely on the field
/// existing).
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

/// Request body for `POST /api/chat/sessions`.
pub const CreateChatSessionRequest = struct {
    agent_id: []const u8,
    title: ?[]const u8 = null,
};

/// Request body for `PATCH /api/chat/sessions/:sessionId`.
pub const UpdateChatSessionRequest = struct {
    title: []const u8,
};

/// Request body for `POST /api/chat/sessions/:sessionId/messages`.
pub const SendChatMessageRequest = struct {
    content: []const u8,
    attachment_ids: []const []const u8 = &.{},
};

/// Response body for the message-send endpoint.
pub const SendChatMessageResponse = struct {
    message_id: []const u8,
    task_id: []const u8,
    created_at: []const u8,
};

/// Cursor for the paginated messages endpoint.
pub const ChatMessagesCursorResponse = struct {
    created_at: []const u8,
    id: []const u8,
};

/// Response body for the paginated messages endpoint.
pub const ChatMessagesPageResponse = struct {
    messages: []ChatMessageResponse,
    limit: i32,
    has_more: bool,
    next_cursor: ?ChatMessagesCursorResponse,
};

/// Response body for `GET /api/chat/sessions/:sessionId/pending-task`.
pub const PendingChatTaskResponse = struct {
    task_id: []const u8,
    status: []const u8,
    created_at: []const u8,
};

/// One row in the `GET /api/chat/pending-tasks` response.
pub const PendingChatTaskItem = struct {
    task_id: []const u8,
    status: []const u8,
    chat_session_id: []const u8,
};

/// Response body for `GET /api/chat/pending-tasks`.
pub const PendingChatTasksResponse = struct {
    tasks: []PendingChatTaskItem,
};

/// Stable pseudo-UUID for the in-memory store. Mirrors the algorithm
/// used by the legacy `src/handlers/chat.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

/// Lightweight UUID-shape check; the DB still enforces the canonical
/// 36-character form on insert.
pub fn looksLikeUuid(s: []const u8) bool {
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
