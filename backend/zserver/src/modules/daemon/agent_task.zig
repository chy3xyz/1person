//! Daemon module — the persistent agent task queue.
//!
//! Chat messages and issue assignments both land in `agent_task_queue`
//! with status 'queued'. That table is the real queue: it survives a
//! server restart, it is shared by every daemon bound to a runtime, and
//! it is what the frontend polls to show "the agent is working".
//!
//! The in-memory queue (`task_queue.zig`) serves a different, narrower
//! purpose: the four maintenance tasks (update / models / local_skills /
//! local_skill_import) that the runtime module hands to a daemon about
//! itself. Both are offered through the same claim endpoint, but only to
//! a daemon that advertised the `agent_tasks` capability — an older
//! daemon keeps seeing exactly the maintenance tasks it understands.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");
const prompt = @import("prompt.zig");

fn borrowDb() ?*zfinal.DB {
    return common_mem.borrowDb();
}

/// One claimed row of the persistent `agent_task_queue`.
pub const AgentTaskRow = struct {
    id: []const u8,
    agent_id: []const u8,
    runtime_id: []const u8,
    issue_id: ?[]const u8,
    chat_session_id: ?[]const u8,
    priority: i64,
    created_at: []const u8,

    pub fn deinit(self: AgentTaskRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.agent_id);
        allocator.free(self.runtime_id);
        if (self.issue_id) |v| allocator.free(v);
        if (self.chat_session_id) |v| allocator.free(v);
        allocator.free(self.created_at);
    }
};

/// The agent's own configuration — what it is called, how it behaves, and
/// which model / provider it should run on.
pub const AgentConfig = struct {
    name: []const u8,
    instructions: []const u8,
    model: []const u8,
    custom_env: []const u8,
    custom_args: []const u8,
    mcp_config: []const u8,
    workspace_id: []const u8,

    pub fn deinit(self: AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.instructions);
        allocator.free(self.model);
        allocator.free(self.custom_env);
        allocator.free(self.custom_args);
        allocator.free(self.mcp_config);
        allocator.free(self.workspace_id);
    }
};

/// The issue an agent was asked to work on.
pub const IssueContext = struct {
    identifier: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: []const u8,

    pub fn deinit(self: IssueContext, allocator: std.mem.Allocator) void {
        allocator.free(self.identifier);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.status);
        allocator.free(self.priority);
    }
};

/// Claim the next queued agent task for a runtime.
///
/// `FOR UPDATE SKIP LOCKED` is what makes two daemons safe against the
/// same queue: the row lock is taken by the UPDATE that flips the status
/// to 'dispatched', and a concurrent claim skips the locked row instead
/// of blocking on it. The ordering matches
/// `idx_agent_task_queue_runtime_pending`.
///
/// Returns null when the queue is empty. The returned row owns its
/// strings — the result set frees its cell text on deinit, so anything
/// that outlives the query has to be copied out.
pub fn claimAgentTask(allocator: std.mem.Allocator, runtime_id: []const u8) !?AgentTaskRow {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "UPDATE agent_task_queue SET status = 'dispatched', dispatched_at = now() " ++
            "WHERE id = (" ++
            "  SELECT id FROM agent_task_queue " ++
            "  WHERE runtime_id = $1::uuid AND status = 'queued' " ++
            "  ORDER BY priority DESC, created_at ASC " ++
            "  FOR UPDATE SKIP LOCKED LIMIT 1" ++
            ") " ++
            "RETURNING id, agent_id, runtime_id, issue_id, chat_session_id, priority, created_at",
        &[_]SqlParam{.{ .text = runtime_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    return AgentTaskRow{
        .id = try allocator.dupe(u8, row.getText(0) orelse ""),
        .agent_id = try allocator.dupe(u8, row.getText(1) orelse ""),
        .runtime_id = try allocator.dupe(u8, row.getText(2) orelse ""),
        .issue_id = if (row.getText(3)) |s| try allocator.dupe(u8, s) else null,
        .chat_session_id = if (row.getText(4)) |s| try allocator.dupe(u8, s) else null,
        .priority = (row.getInt(5) catch null) orelse 0,
        .created_at = try allocator.dupe(u8, row.getText(6) orelse ""),
    };
}

/// Move an agent task to a new status.
///
/// The status column is the contract the frontend polls
/// (`getPendingChatTask` treats queued / dispatched / running /
/// waiting_local_directory as "still working"), so the transition has to
/// happen in the same database the frontend reads.
pub fn setAgentTaskStatus(task_id: []const u8, status: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    _ = db.execParams(
        "UPDATE agent_task_queue SET status = $1, " ++
            "started_at = CASE WHEN $1 = 'running' THEN now() ELSE started_at END, " ++
            "completed_at = CASE WHEN $1 IN ('completed', 'failed', 'cancelled') THEN now() ELSE completed_at END " ++
            "WHERE id = $2::uuid",
        &[_]SqlParam{
            .{ .text = status },
            .{ .text = task_id },
        },
    ) catch return false;
    return true;
}

/// Complete an agent task and store its result payload.
///
/// The result is stored as JSONB so the frontend can render it later
/// (usage, output text) without the daemon having to push it a second time.
pub fn completeAgentTask(task_id: []const u8, result_json: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    const payload = if (std.mem.trim(u8, result_json, " \t\r\n").len == 0) "{}" else result_json;
    _ = db.execParams(
        "UPDATE agent_task_queue SET status = 'completed', completed_at = now(), result = $2::jsonb " ++
            "WHERE id = $1::uuid",
        &[_]SqlParam{
            .{ .text = task_id },
            .{ .text = payload },
        },
    ) catch return false;
    return true;
}

/// The coarse class a failure belongs to.
///
/// The frontend renders this as a label next to the task row, so the
/// values have to stay inside the set it knows. A run that ran out of
/// time is a timeout; anything else is the agent's own error.
pub const failure_reason_runtime = "runtime_offline";
pub const failure_reason_timeout = "timeout";
pub const failure_reason_agent_error = "agent_error";

/// Classify a failure reason the daemon reported.
///
/// The reason comes from a CLI, so it can be written in any case — the
/// comparison is ASCII-only and allocates nothing, because this runs on
/// every failed task.
pub fn classifyFailure(err_msg: []const u8) []const u8 {
    if (containsIgnoreCase(err_msg, "timeout") or
        containsIgnoreCase(err_msg, "timed out") or
        containsIgnoreCase(err_msg, "deadline"))
    {
        return failure_reason_timeout;
    }
    return failure_reason_agent_error;
}

/// Case-insensitive substring search over ASCII.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Mark an agent task as failed, with the reason the daemon reported.
///
/// `failure_reason` is the coarse class the frontend renders as a label
/// next to the task row; `error` carries the full text. The two are
/// separate columns upstream and the frontend reads both, so a failure
/// that only fills `error` shows up without a reason label.
pub fn failAgentTask(task_id: []const u8, err_msg: []const u8, failure_reason: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    _ = db.execParams(
        "UPDATE agent_task_queue SET status = 'failed', completed_at = now(), " ++
            "error = $2, failure_reason = $3 " ++
            "WHERE id = $1::uuid",
        &[_]SqlParam{
            .{ .text = task_id },
            .{ .text = err_msg },
            .{ .text = failure_reason },
        },
    ) catch return false;
    return true;
}

/// Where a task's answer has to be delivered.
///
/// The daemon reports completion with the task id only, so the server
/// looks up what the task was about when it materializes the answer.
pub const TaskTarget = struct {
    agent_id: []const u8,
    workspace_id: []const u8,
    issue_id: ?[]const u8,
    chat_session_id: ?[]const u8,

    pub fn deinit(self: TaskTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.workspace_id);
        if (self.issue_id) |v| allocator.free(v);
        if (self.chat_session_id) |v| allocator.free(v);
    }
};

/// Read what a task is about.
pub fn selectTaskTarget(allocator: std.mem.Allocator, task_id: []const u8) !?TaskTarget {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT atq.agent_id, a.workspace_id, atq.issue_id, atq.chat_session_id " ++
            "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
            "WHERE atq.id = $1::uuid",
        &[_]SqlParam{.{ .text = task_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    return TaskTarget{
        .agent_id = try allocator.dupe(u8, row.getText(0) orelse ""),
        .workspace_id = try allocator.dupe(u8, row.getText(1) orelse ""),
        .issue_id = if (row.getText(2)) |s| try allocator.dupe(u8, s) else null,
        .chat_session_id = if (row.getText(3)) |s| try allocator.dupe(u8, s) else null,
    };
}

/// Read the agent that owns a task — needed by the result write-back,
/// which only receives the task id.
pub fn selectTaskAgentId(allocator: std.mem.Allocator, task_id: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT agent_id FROM agent_task_queue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = task_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

/// Read the agent's configuration.
pub fn selectAgentConfig(allocator: std.mem.Allocator, agent_id: []const u8) !?AgentConfig {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT name, instructions, model, custom_env, custom_args, mcp_config, workspace_id " ++
            "FROM agent WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = agent_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    return AgentConfig{
        .name = try allocator.dupe(u8, row.getText(0) orelse ""),
        .instructions = try allocator.dupe(u8, row.getText(1) orelse ""),
        .model = try allocator.dupe(u8, row.getText(2) orelse ""),
        .custom_env = try allocator.dupe(u8, row.getText(3) orelse "{}"),
        .custom_args = try allocator.dupe(u8, row.getText(4) orelse "[]"),
        .mcp_config = try allocator.dupe(u8, row.getText(5) orelse "{}"),
        .workspace_id = try allocator.dupe(u8, row.getText(6) orelse ""),
    };
}

/// Read the provider the runtime's daemon registered with.
///
/// `provider` is what the daemon says it can actually run (the local CLI
/// it found on PATH), so the server never has to guess.
pub fn selectRuntimeProvider(allocator: std.mem.Allocator, runtime_id: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT provider FROM agent_runtime WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = runtime_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

/// Read the workspace's display name and issue prefix.
pub fn selectWorkspaceInfo(allocator: std.mem.Allocator, workspace_id: []const u8) !?struct { name: []const u8, issue_prefix: []const u8 } {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT name, issue_prefix FROM workspace WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = workspace_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    return .{
        .name = try allocator.dupe(u8, row.getText(0) orelse ""),
        .issue_prefix = try allocator.dupe(u8, row.getText(1) orelse ""),
    };
}

/// Read the issue an agent was asked to work on.
pub fn selectIssueContext(allocator: std.mem.Allocator, issue_id: []const u8, issue_prefix: []const u8) !?IssueContext {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT number, title, description, status, priority FROM issue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = issue_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    const number = (row.getInt(0) catch null) orelse 0;
    const identifier = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ issue_prefix, number });
    return IssueContext{
        .identifier = identifier,
        .title = try allocator.dupe(u8, row.getText(1) orelse ""),
        .description = try allocator.dupe(u8, row.getText(2) orelse ""),
        .status = try allocator.dupe(u8, row.getText(3) orelse ""),
        .priority = try allocator.dupe(u8, row.getText(4) orelse ""),
    };
}

/// Read the comments on an issue, oldest first.
///
/// Bounded: an issue with a long comment thread would otherwise blow up
/// the prompt. The newest comments are the ones that matter for the
/// current run, so the window keeps the tail.
pub fn selectIssueComments(allocator: std.mem.Allocator, issue_id: []const u8) ![]prompt.IssueComment {
    const db = borrowDb() orelse return &[_]prompt.IssueComment{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT author_type, content FROM comment WHERE issue_id = $1::uuid " ++
            "ORDER BY created_at DESC LIMIT 30",
        &[_]SqlParam{.{ .text = issue_id }},
    );
    defer rs.deinit();

    var list: std.ArrayList(prompt.IssueComment) = .empty;
    errdefer {
        for (list.items) |c| {
            allocator.free(c.author);
            allocator.free(c.content);
        }
        list.deinit(allocator);
    }
    // Walk the result set backwards: the query returns newest-first (so
    // the LIMIT keeps the recent tail) and the prompt reads better in
    // chronological order.
    var i = rs.rows.items.len;
    while (i > 0) {
        i -= 1;
        const row = &rs.rows.items[i];
        const author_type = row.getText(0) orelse "member";
        const author = if (std.mem.eql(u8, author_type, "agent")) "agent" else "user";
        try list.append(allocator, .{
            .author = try allocator.dupe(u8, author),
            .content = try allocator.dupe(u8, row.getText(1) orelse ""),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Read the chat transcript of a session, oldest first.
///
/// The last turn is the user's request; the rest is context. The window
/// is bounded for the same reason as the issue comments.
pub fn selectChatHistory(allocator: std.mem.Allocator, session_id: []const u8) ![]prompt.ChatTurn {
    const db = borrowDb() orelse return &[_]prompt.ChatTurn{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT role, content FROM chat_message WHERE chat_session_id = $1::uuid " ++
            "ORDER BY created_at DESC LIMIT 40",
        &[_]SqlParam{.{ .text = session_id }},
    );
    defer rs.deinit();

    var list: std.ArrayList(prompt.ChatTurn) = .empty;
    errdefer {
        for (list.items) |turn| {
            allocator.free(turn.role);
            allocator.free(turn.content);
        }
        list.deinit(allocator);
    }
    var i = rs.rows.items.len;
    while (i > 0) {
        i -= 1;
        const row = &rs.rows.items[i];
        try list.append(allocator, .{
            .role = try allocator.dupe(u8, row.getText(0) orelse "user"),
            .content = try allocator.dupe(u8, row.getText(1) orelse ""),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Post the agent's answer as an assistant message in the chat session.
///
/// This is what the user sees: the daemon's output, delivered as the
/// assistant's turn, linked back to the task that produced it.
pub fn insertAssistantMessage(allocator: std.mem.Allocator, session_id: []const u8, task_id: []const u8, content: []const u8) !?[]const u8 {
    return insertAssistantMessageWithReason(allocator, session_id, task_id, content, null);
}

/// Post an assistant message, optionally tagged with why the turn ended.
///
/// A failure message carries the failure class so the chat UI can tell
/// "the agent answered" from "the agent could not answer".
pub fn insertAssistantMessageWithReason(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    task_id: []const u8,
    content: []const u8,
    failure_reason: ?[]const u8,
) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "INSERT INTO chat_message (chat_session_id, role, content, task_id, failure_reason) " ++
            "VALUES ($1::uuid, 'assistant', $2, $3::uuid, $4) RETURNING id",
        &[_]SqlParam{
            .{ .text = session_id },
            .{ .text = content },
            .{ .text = task_id },
            .{ .text = failure_reason orelse "" },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

/// Post the agent's answer as a comment on the issue.
pub fn insertAgentComment(allocator: std.mem.Allocator, workspace_id: []const u8, issue_id: []const u8, agent_id: []const u8, content: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "INSERT INTO comment (issue_id, workspace_id, author_type, author_id, content, type) " ++
            "VALUES ($1::uuid, $2::uuid, 'agent', $3::uuid, $4, 'comment') RETURNING id",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            .{ .text = agent_id },
            .{ .text = content },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classifyFailure: a run that ran out of time is a timeout" {
    try testing.expectEqualStrings(failure_reason_timeout, classifyFailure("agent CLI timed out after 300s"));
    try testing.expectEqualStrings(failure_reason_timeout, classifyFailure("Timeout exceeded"));
    try testing.expectEqualStrings(failure_reason_timeout, classifyFailure("deadline exceeded"));
}

test "classifyFailure: anything else is the agent's own error" {
    try testing.expectEqualStrings(failure_reason_agent_error, classifyFailure("Free usage limit reached"));
    try testing.expectEqualStrings(failure_reason_agent_error, classifyFailure(""));
}

test "containsIgnoreCase: matches regardless of case" {
    try testing.expect(containsIgnoreCase("Free TIMEOUT reached", "timeout"));
    try testing.expect(containsIgnoreCase("free timeout reached", "TIMEOUT"));
    try testing.expect(!containsIgnoreCase("free limit reached", "timeout"));
    try testing.expect(!containsIgnoreCase("short", "a much longer needle"));
}
