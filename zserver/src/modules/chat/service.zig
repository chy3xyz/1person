//! Chat module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_sessions`,
//! `mem_messages`, `mem_tasks` tables) and exposes the nine
//! HTTP-facing operations: `listChatSessions`, `createChatSession`,
//! `getChatSession`, `updateChatSession`, `deleteChatSession`,
//! `sendChatMessage`, `listChatMessages`, `listChatMessagesPage`,
//! `getPendingChatTask`, `markChatSessionRead`,
//! `listPendingChatTasks`. The `handler.zig` is a thin delegate; SQL
//! and data shapes live in `model.zig`.
//!
//! The realtime integration (`realtime.publishChatMessage`) is the only
//! cross-module side-effect: when a new user message is enqueued, the
//! service emits a JSON envelope to any locally-connected clients in
//! the same workspace so their chat UIs can append the row in real
//! time. The realtime module is imported from `src/handlers/realtime.zig`
//! to avoid re-implementing the WebSocket ring buffer here.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const realtime = @import("../../modules/realtime/service.zig");
const model = @import("model.zig");

const log = std.log.scoped(.chat_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_sessions: ?std.StringHashMap(model.ChatSessionEntry) = null;
var mem_messages: ?std.StringHashMap(std.ArrayList(model.ChatMessageEntry)) = null;
var mem_tasks: ?std.StringHashMap(model.ChatTaskEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_sessions == null) {
        mem_sessions = std.StringHashMap(model.ChatSessionEntry).init(memAlloc());
        mem_messages = std.StringHashMap(std.ArrayList(model.ChatMessageEntry)).init(memAlloc());
        mem_tasks = std.StringHashMap(model.ChatTaskEntry).init(memAlloc());
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

fn sessionResponseFromEntry(entry: model.ChatSessionEntry) model.ChatSessionResponse {
    return model.ChatSessionResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .agent_id = entry.agent_id,
        .creator_id = entry.creator_id,
        .title = entry.title,
        .status = entry.status,
        .has_unread = entry.has_unread,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

fn sessionResponseFromRow(rs: *zfinal.ResultSet, row: usize) model.ChatSessionResponse {
    const r = &rs.rows.items[row];
    const unread_text = r.getText(6) orelse "";
    return model.ChatSessionResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .agent_id = r.getText(2) orelse "",
        .creator_id = r.getText(3) orelse "",
        .title = r.getText(4) orelse "",
        .status = r.getText(5) orelse "",
        .has_unread = std.mem.eql(u8, unread_text, "t") or
            std.mem.eql(u8, unread_text, "true") or
            std.mem.eql(u8, unread_text, "1"),
        .created_at = r.getText(7) orelse "",
        .updated_at = r.getText(8) orelse "",
    };
}

fn messageResponseFromEntry(entry: model.ChatMessageEntry) model.ChatMessageResponse {
    return model.ChatMessageResponse{
        .id = entry.id,
        .chat_session_id = entry.chat_session_id,
        .role = entry.role,
        .content = entry.content,
        .task_id = if (entry.task_id.len > 0) entry.task_id else null,
        .created_at = entry.created_at,
        .failure_reason = if (entry.failure_reason.len > 0) entry.failure_reason else null,
        .elapsed_ms = if (entry.elapsed_ms >= 0) entry.elapsed_ms else null,
        .attachments = &.{},
    };
}

fn messageResponseFromRow(rs: *zfinal.ResultSet, row: usize) model.ChatMessageResponse {
    const r = &rs.rows.items[row];
    const elapsed_ms: ?i64 = if (r.cells.len > 7 and r.cells[7] == .null)
        null
    else
        @intCast(std.fmt.parseInt(i64, r.getText(7) orelse "0", 10) catch 0);
    return model.ChatMessageResponse{
        .id = r.getText(0) orelse "",
        .chat_session_id = r.getText(1) orelse "",
        .role = r.getText(2) orelse "",
        .content = r.getText(3) orelse "",
        .task_id = r.getText(4),
        .created_at = r.getText(5) orelse "",
        .failure_reason = r.getText(6),
        .elapsed_ms = elapsed_ms,
        .attachments = &.{},
    };
}

fn loadSession(ctx: *zfinal.Context, session_id: []const u8) !?model.ChatSessionEntry {
    const workspace_id = getWorkspaceId(ctx) orelse return null;
    const user_id = getUserId(ctx) orelse return null;

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, workspace_id, agent_id, creator_id, title, status, has_unread, created_at, updated_at " ++
                "FROM chat_session WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = session_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        const entry = sessionResponseFromRow(&rs, 0);
        if (!std.mem.eql(u8, entry.creator_id, user_id)) return null;

        // Duplicate text fields using db allocator to avoid use-after-free
        // (rs is deinit'd on return via defer above).
        const id = d.allocator.dupe(u8, entry.id) catch return null;
        const ws_id = d.allocator.dupe(u8, entry.workspace_id) catch {
            d.allocator.free(id);
            return null;
        };
        const ag_id = d.allocator.dupe(u8, entry.agent_id) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            return null;
        };
        const cr_id = d.allocator.dupe(u8, entry.creator_id) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            d.allocator.free(ag_id);
            return null;
        };
        const title = d.allocator.dupe(u8, entry.title) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            d.allocator.free(ag_id);
            d.allocator.free(cr_id);
            return null;
        };
        const status = d.allocator.dupe(u8, entry.status) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            d.allocator.free(ag_id);
            d.allocator.free(cr_id);
            d.allocator.free(title);
            return null;
        };
        const created_at = d.allocator.dupe(u8, entry.created_at) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            d.allocator.free(ag_id);
            d.allocator.free(cr_id);
            d.allocator.free(title);
            d.allocator.free(status);
            return null;
        };
        const updated_at = d.allocator.dupe(u8, entry.updated_at) catch {
            d.allocator.free(id);
            d.allocator.free(ws_id);
            d.allocator.free(ag_id);
            d.allocator.free(cr_id);
            d.allocator.free(title);
            d.allocator.free(status);
            d.allocator.free(created_at);
            return null;
        };
        return model.ChatSessionEntry{
            .id = id,
            .workspace_id = ws_id,
            .agent_id = ag_id,
            .creator_id = cr_id,
            .title = title,
            .status = status,
            .has_unread = entry.has_unread,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    } else {
        try memInit();
        const entry = mem_sessions.?.get(session_id) orelse return null;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
        if (!std.mem.eql(u8, entry.creator_id, user_id)) return null;
        return entry;
    }
}

pub fn listChatSessions(ctx: *zfinal.Context) !void {
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
            "SELECT id, workspace_id, agent_id, creator_id, title, status, has_unread, created_at, updated_at " ++
                "FROM chat_session WHERE workspace_id = $1::uuid AND creator_id = $2::uuid " ++
                "ORDER BY updated_at DESC",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        var list: std.ArrayList(model.ChatSessionResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, sessionResponseFromRow(&rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.ChatSessionResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_sessions.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.creator_id, user_id)) continue;
            try list.append(allocator, sessionResponseFromEntry(entry));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn createChatSession(ctx: *zfinal.Context) !void {
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

    const parsed = try ctx.parseJsonBody(model.CreateChatSessionRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.agent_id.len == 0 or !model.looksLikeUuid(req.agent_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "agent_id is required" });
        return;
    }

    const title = std.mem.trim(u8, req.title orelse "", &std.ascii.whitespace);

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        var agent_check = try d.queryParams(
            "SELECT 1 FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL",
            &[_]SqlParam{ .{ .text = req.agent_id }, .{ .text = workspace_id } },
        );
        defer agent_check.deinit();
        if (agent_check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "agent not found" });
            return;
        }

        var rs = try d.queryParams(
            "INSERT INTO chat_session (workspace_id, agent_id, creator_id, title) " ++
                "VALUES ($1::uuid, $2::uuid, $3::uuid, $4) " ++
                "RETURNING id, workspace_id, agent_id, creator_id, title, status, has_unread, created_at, updated_at",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = req.agent_id },
                .{ .text = user_id },
                .{ .text = title },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create chat session" });
            return;
        }
        ctx.res_status = .created;
        try ctx.renderJson(sessionResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = try model.generateId(allocator, req.agent_id);
        const now = try nowString();
        const entry = model.ChatSessionEntry{
            .id = try memDup(id),
            .workspace_id = try memDup(workspace_id),
            .agent_id = try memDup(req.agent_id),
            .creator_id = try memDup(user_id),
            .title = try memDup(title),
            .status = try memDup("active"),
            .has_unread = false,
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
        };
        try mem_sessions.?.put(entry.id, entry);
        ctx.res_status = .created;
        try ctx.renderJson(sessionResponseFromEntry(entry));
    }
}

pub fn getChatSession(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    const entry = (try loadSession(ctx, session_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "chat session not found" });
        return;
    };
    try ctx.renderJson(sessionResponseFromEntry(entry));
}

pub fn updateChatSession(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateChatSessionRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const title = std.mem.trim(u8, req.title, &std.ascii.whitespace);
    if (title.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "title is required" });
        return;
    }

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
            "UPDATE chat_session SET title = $4, updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid AND creator_id = $3::uuid " ++
                "RETURNING id, workspace_id, agent_id, creator_id, title, status, has_unread, created_at, updated_at",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
                .{ .text = title },
            },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        }
        try ctx.renderJson(sessionResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_sessions.?.getPtr(session_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id) or
            !std.mem.eql(u8, entry_ptr.creator_id, user_id))
        {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        }
        entry_ptr.title = try memDup(title);
        entry_ptr.updated_at = try nowString();
        try ctx.renderJson(sessionResponseFromEntry(entry_ptr.*));
    }
}

pub fn deleteChatSession(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };
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
        try d.execParams(
            "DELETE FROM chat_session WHERE id = $1::uuid AND workspace_id = $2::uuid AND creator_id = $3::uuid",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
            },
        );
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_sessions.?.get(session_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id) or
            !std.mem.eql(u8, entry.creator_id, user_id))
        {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        }
        _ = mem_sessions.?.fetchRemove(session_id);
        _ = mem_messages.?.fetchRemove(session_id);
        ctx.res_status = .no_content;
    }
}

pub fn sendChatMessage(ctx: *zfinal.Context) !void {
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
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.SendChatMessageRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const content = std.mem.trim(u8, req.content, &std.ascii.whitespace);
    if (content.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "content is required" });
        return;
    }

    const session = (try loadSession(ctx, session_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "chat session not found" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        var msg_res = try d.queryParams(
            "INSERT INTO chat_message (chat_session_id, role, content) " ++
                "VALUES ($1::uuid, 'user', $2) RETURNING id, created_at",
            &[_]SqlParam{ .{ .text = session_id }, .{ .text = content } },
        );
        defer msg_res.deinit();
        if (msg_res.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create chat message" });
            return;
        }
        const message_id = msg_res.rows.items[0].getText(0) orelse "";
        const message_created_at = msg_res.rows.items[0].getText(1) orelse "";

        var agent_res = try d.queryParams(
            "SELECT runtime_id FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = session.agent_id }, .{ .text = workspace_id } },
        );
        defer agent_res.deinit();
        const runtime_id: ?[]const u8 = if (agent_res.rows.items.len > 0)
            agent_res.rows.items[0].getText(0)
        else
            null;

        const task_params = if (runtime_id) |rid| [_]SqlParam{
            .{ .text = session.agent_id },
            .{ .text = rid },
            .{ .text = "0" },
            .{ .text = session_id },
            .{ .text = user_id },
        } else [_]SqlParam{
            .{ .text = session.agent_id },
            .{ .text = "" },
            .{ .text = "0" },
            .{ .text = session_id },
            .{ .text = user_id },
        };
        var task_res = try d.queryParams(
            "INSERT INTO agent_task_queue (agent_id, runtime_id, issue_id, status, priority, chat_session_id, initiator_user_id) " ++
                "VALUES ($1::uuid, NULLIF($2, '')::uuid, NULL, 'queued', $3::int, $4::uuid, $5::uuid) " ++
                "RETURNING id, created_at",
            &task_params,
        );
        defer task_res.deinit();
        if (task_res.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to enqueue chat task" });
            return;
        }
        const task_id = task_res.rows.items[0].getText(0) orelse "";
        const task_created_at = task_res.rows.items[0].getText(1) orelse "";

        try d.execParams(
            "UPDATE chat_message SET task_id = $1::uuid WHERE id = $2::uuid",
            &[_]SqlParam{ .{ .text = task_id }, .{ .text = message_id } },
        );

        try d.execParams(
            "UPDATE chat_session SET updated_at = now() WHERE id = $1::uuid",
            &[_]SqlParam{.{ .text = session_id }},
        );

        ctx.res_status = .created;
        try ctx.renderJson(model.SendChatMessageResponse{
            .message_id = message_id,
            .task_id = task_id,
            .created_at = task_created_at,
        });
        _ = message_created_at;

        // Best-effort: notify any locally-connected clients in this workspace.
        const payload = std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"{s}\",\"chat_session_id\":\"{s}\",\"role\":\"user\"," ++
                "\"content\":{f},\"task_id\":\"{s}\",\"created_at\":\"{s}\"}}",
            .{
                message_id,
                session_id,
                std.json.fmt(content, .{}),
                task_id,
                task_created_at,
            },
        ) catch null;
        if (payload) |p| {
            defer allocator.free(p);
            realtime.publishChatMessage(workspace_id, session_id, p);
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const now = try nowString();
        const message_id = try model.generateId(allocator, content);
        const task_id = try model.generateId(allocator, session_id);

        // The session_id comes from the request path/body; the in-
        // memory hashmap stores it as the key, so we must memDup it
        // to avoid a dangling pointer on the next request.
        const stable_session_id = try memDup(session_id);
        var messages = mem_messages.?.getPtr(stable_session_id) orelse b: {
            try mem_messages.?.put(stable_session_id, std.ArrayList(model.ChatMessageEntry).empty);
            break :b mem_messages.?.getPtr(stable_session_id).?;
        };
        const msg_entry = model.ChatMessageEntry{
            .id = try memDup(message_id),
            .chat_session_id = try memDup(session_id),
            .role = try memDup("user"),
            .content = try memDup(content),
            .task_id = try memDup(task_id),
            .created_at = try memDup(now),
            .failure_reason = try memDup(""),
            .elapsed_ms = -1,
        };
        try messages.append(memAlloc(), msg_entry);

        const task_entry = model.ChatTaskEntry{
            .id = try memDup(task_id),
            .chat_session_id = try memDup(session_id),
            .workspace_id = try memDup(workspace_id),
            .creator_id = try memDup(user_id),
            .status = try memDup("queued"),
            .type = try memDup("chat"),
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
        };
        try mem_tasks.?.put(task_entry.id, task_entry);

        const session_ptr = mem_sessions.?.getPtr(session_id).?;
        session_ptr.updated_at = try memDup(now);

        ctx.res_status = .created;
        try ctx.renderJson(model.SendChatMessageResponse{
            .message_id = message_id,
            .task_id = task_id,
            .created_at = now,
        });

        // Best-effort: notify any locally-connected clients in this workspace.
        const payload = std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"{s}\",\"chat_session_id\":\"{s}\",\"role\":\"user\"," ++
                "\"content\":{f},\"task_id\":\"{s}\",\"created_at\":\"{s}\"}}",
            .{
                message_id,
                session_id,
                std.json.fmt(content, .{}),
                task_id,
                now,
            },
        ) catch null;
        if (payload) |p| {
            defer allocator.free(p);
            realtime.publishChatMessage(workspace_id, session_id, p);
        }
    }
}

pub fn listChatMessages(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    const session = (try loadSession(ctx, session_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "chat session not found" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, chat_session_id, role, content, task_id, created_at, failure_reason, elapsed_ms " ++
                "FROM chat_message WHERE chat_session_id = $1::uuid ORDER BY created_at ASC",
            &[_]SqlParam{.{ .text = session_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.ChatMessageResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, messageResponseFromRow(&rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.ChatMessageResponse) = .empty;
        defer list.deinit(allocator);
        const messages = mem_messages.?.get(session_id) orelse {
            try ctx.renderJson(list.items);
            return;
        };
        for (messages.items) |msg| {
            if (!std.mem.eql(u8, msg.chat_session_id, session.id)) continue;
            try list.append(allocator, messageResponseFromEntry(msg));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn listChatMessagesPage(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    const session = (try loadSession(ctx, session_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "chat session not found" });
        return;
    };

    const limit_str = ctx.getPara("limit") catch null;
    var limit: i32 = 50;
    if (limit_str) |s| {
        limit = std.fmt.parseInt(i32, s, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid limit" });
            return;
        };
        if (limit < 1 or limit > 100) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid limit" });
            return;
        }
    }
    const before_created_at = ctx.getPara("before_created_at") catch null;
    const before_id = ctx.getPara("before_id") catch null;

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        // Fetch limit+1 rows so `has_more` can be computed from the
        // actual row count instead of always being false.
        const limit_param = try std.fmt.allocPrint(allocator, "{d}", .{limit + 1});
        defer allocator.free(limit_param);

        var rs: zfinal.ResultSet = if (before_created_at != null and before_id != null) try d.queryParams(
            "SELECT id, chat_session_id, role, content, task_id, created_at, failure_reason, elapsed_ms " ++
                "FROM chat_message WHERE chat_session_id = $1::uuid " ++
                "AND (created_at, id) < ($2::timestamptz, $3::uuid) " ++
                "ORDER BY created_at DESC, id DESC LIMIT $4::int",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = before_created_at.? },
                .{ .text = before_id.? },
                .{ .text = limit_param },
            },
        ) else try d.queryParams(
            "SELECT id, chat_session_id, role, content, task_id, created_at, failure_reason, elapsed_ms " ++
                "FROM chat_message WHERE chat_session_id = $1::uuid " ++
                "ORDER BY created_at DESC, id DESC LIMIT $2::int",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = limit_param },
            },
        );
        defer rs.deinit();

        var list: std.ArrayList(model.ChatMessageResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, messageResponseFromRow(&rs, i));
        }

        const has_more = list.items.len > @as(usize, @intCast(limit));
        if (has_more) {
            _ = list.pop();
        }
        std.mem.reverse(model.ChatMessageResponse, list.items);

        var next_cursor: ?model.ChatMessagesCursorResponse = null;
        if (has_more and list.items.len > 0) {
            const last = list.items[list.items.len - 1];
            next_cursor = model.ChatMessagesCursorResponse{
                .created_at = last.created_at,
                .id = last.id,
            };
        }

        try ctx.renderJson(model.ChatMessagesPageResponse{
            .messages = list.items,
            .limit = limit,
            .has_more = has_more,
            .next_cursor = next_cursor,
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var all: std.ArrayList(model.ChatMessageResponse) = .empty;
        defer all.deinit(allocator);
        const messages = mem_messages.?.get(session_id) orelse {
            try ctx.renderJson(model.ChatMessagesPageResponse{
                .messages = &.{},
                .limit = limit,
                .has_more = false,
                .next_cursor = null,
            });
            return;
        };
        for (messages.items) |msg| {
            if (!std.mem.eql(u8, msg.chat_session_id, session.id)) continue;
            try all.append(allocator, messageResponseFromEntry(msg));
        }

        const SortCtx = struct {
            pub fn less(_: @This(), a: model.ChatMessageResponse, b: model.ChatMessageResponse) bool {
                const ord = std.mem.order(u8, b.created_at, a.created_at);
                if (ord != .eq) return ord == .gt;
                return std.mem.order(u8, b.id, a.id) == .gt;
            }
        };
        std.mem.sort(model.ChatMessageResponse, all.items, SortCtx{}, SortCtx.less);

        var list: std.ArrayList(model.ChatMessageResponse) = .empty;
        defer list.deinit(allocator);
        var idx: usize = 0;
        if (before_created_at != null and before_id != null) {
            for (all.items, 0..) |item, i| {
                const ord = std.mem.order(u8, item.created_at, before_created_at.?);
                if (ord == .lt or (ord == .eq and std.mem.order(u8, item.id, before_id.?) == .lt)) {
                    idx = i;
                    break;
                }
            }
        }
        const end = @min(idx + @as(usize, @intCast(limit)), all.items.len);
        for (idx..end) |i| {
            try list.append(allocator, all.items[i]);
        }
        const has_more = end < all.items.len;
        std.mem.reverse(model.ChatMessageResponse, list.items);

        var next_cursor: ?model.ChatMessagesCursorResponse = null;
        if (has_more and list.items.len > 0) {
            const last = list.items[list.items.len - 1];
            next_cursor = model.ChatMessagesCursorResponse{
                .created_at = last.created_at,
                .id = last.id,
            };
        }

        try ctx.renderJson(model.ChatMessagesPageResponse{
            .messages = list.items,
            .limit = limit,
            .has_more = has_more,
            .next_cursor = next_cursor,
        });
    }
}

pub fn getPendingChatTask(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    _ = (try loadSession(ctx, session_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "chat session not found" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, status, created_at FROM agent_task_queue " ++
                "WHERE chat_session_id = $1::uuid AND status IN ('queued', 'dispatched', 'running', 'waiting_local_directory') " ++
                "ORDER BY created_at DESC LIMIT 1",
            &[_]SqlParam{.{ .text = session_id }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            try ctx.renderJson(model.PendingChatTaskResponse{
                .task_id = "",
                .status = "",
                .created_at = "",
            });
            return;
        }
        try ctx.renderJson(model.PendingChatTaskResponse{
            .task_id = rs.rows.items[0].getText(0) orelse "",
            .status = rs.rows.items[0].getText(1) orelse "",
            .created_at = rs.rows.items[0].getText(2) orelse "",
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var latest: ?model.ChatTaskEntry = null;
        var it = mem_tasks.?.iterator();
        while (it.next()) |e| {
            const task = e.value_ptr.*;
            if (!std.mem.eql(u8, task.chat_session_id, session_id)) continue;
            if (!std.mem.eql(u8, task.status, "queued") and
                !std.mem.eql(u8, task.status, "dispatched") and
                !std.mem.eql(u8, task.status, "running") and
                !std.mem.eql(u8, task.status, "waiting_local_directory")) continue;
            if (latest == null or std.mem.order(u8, task.created_at, latest.?.created_at) == .gt) {
                latest = task;
            }
        }
        if (latest) |task| {
            try ctx.renderJson(model.PendingChatTaskResponse{
                .task_id = task.id,
                .status = task.status,
                .created_at = task.created_at,
            });
        } else {
            try ctx.renderJson(model.PendingChatTaskResponse{
                .task_id = "",
                .status = "",
                .created_at = "",
            });
        }
    }
}

pub fn markChatSessionRead(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };
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
        try d.execParams(
            "UPDATE chat_session SET has_unread = false, updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid AND creator_id = $3::uuid",
            &[_]SqlParam{
                .{ .text = session_id },
                .{ .text = workspace_id },
                .{ .text = user_id },
            },
        );
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_sessions.?.getPtr(session_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        };
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id) or
            !std.mem.eql(u8, entry_ptr.creator_id, user_id))
        {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "chat session not found" });
            return;
        }
        entry_ptr.has_unread = false;
        entry_ptr.updated_at = try nowString();
        ctx.res_status = .no_content;
    }
}

pub fn listPendingChatTasks(ctx: *zfinal.Context) !void {
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
            "SELECT atq.id AS task_id, atq.status, atq.chat_session_id " ++
                "FROM agent_task_queue atq " ++
                "JOIN chat_session cs ON cs.id = atq.chat_session_id " ++
                "WHERE cs.workspace_id = $1::uuid AND cs.creator_id = $2::uuid " ++
                "AND atq.status IN ('queued', 'dispatched', 'running', 'waiting_local_directory') " ++
                "ORDER BY atq.created_at DESC",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        var list: std.ArrayList(model.PendingChatTaskItem) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.PendingChatTaskItem{
                .task_id = r.getText(0) orelse "",
                .status = r.getText(1) orelse "",
                .chat_session_id = r.getText(2) orelse "",
            });
        }
        try ctx.renderJson(model.PendingChatTasksResponse{ .tasks = list.items });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.PendingChatTaskItem) = .empty;
        defer list.deinit(allocator);
        var it = mem_tasks.?.iterator();
        while (it.next()) |e| {
            const task = e.value_ptr.*;
            if (!std.mem.eql(u8, task.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, task.creator_id, user_id)) continue;
            if (!std.mem.eql(u8, task.status, "queued") and
                !std.mem.eql(u8, task.status, "dispatched") and
                !std.mem.eql(u8, task.status, "running") and
                !std.mem.eql(u8, task.status, "waiting_local_directory")) continue;
            try list.append(allocator, model.PendingChatTaskItem{
                .task_id = task.id,
                .status = task.status,
                .chat_session_id = task.chat_session_id,
            });
        }
        try ctx.renderJson(model.PendingChatTasksResponse{ .tasks = list.items });
    }
}
