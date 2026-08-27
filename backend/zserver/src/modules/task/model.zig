//! Task module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.
//!
//! Note: the legacy `SELECT *` queries are preserved verbatim —
//! `taskResponseFromRow` indexes into specific column positions of
//! the `agent_task_queue` schema, and `taskMessagePayloadFromRow`
//! does the same for `task_message`. Changing those mappings would
//! silently break response shape.

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

/// `agent_task_queue` row.
pub const TaskEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    agent_id: []const u8,
    runtime_id: ?[]const u8,
    issue_id: ?[]const u8,
    chat_session_id: ?[]const u8,
    status: []const u8,
    priority: i32,
    created_at: []const u8,
    updated_at: []const u8,
};

/// `task_message` row.
pub const TaskMessageEntry = struct {
    id: []const u8,
    task_id: []const u8,
    seq: i32,
    type: []const u8,
    tool: ?[]const u8,
    content: ?[]const u8,
    input: ?[]const u8,
    output: ?[]const u8,
    created_at: []const u8,
};

/// API response shape for `agent_task_queue` rows.
pub const AgentTaskResponse = struct {
    id: []const u8,
    agent_id: []const u8,
    runtime_id: ?[]const u8,
    issue_id: ?[]const u8,
    workspace_id: []const u8,
    chat_session_id: ?[]const u8,
    status: []const u8,
    priority: i32,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Payload shape for individual task messages.
pub const TaskMessagePayload = struct {
    task_id: []const u8,
    issue_id: ?[]const u8,
    seq: i32,
    type: []const u8,
    tool: ?[]const u8,
    content: ?[]const u8,
    input: ?std.json.Value,
    output: ?[]const u8,
    created_at: ?[]const u8,
};

pub fn taskResponseFromEntry(entry: TaskEntry) AgentTaskResponse {
    return AgentTaskResponse{
        .id = entry.id,
        .agent_id = entry.agent_id,
        .runtime_id = entry.runtime_id,
        .issue_id = entry.issue_id,
        .workspace_id = entry.workspace_id,
        .chat_session_id = entry.chat_session_id,
        .status = entry.status,
        .priority = entry.priority,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// `res` is the result of `SELECT * FROM agent_task_queue ...`.
/// Column positions match the `agent_task_queue` schema.
pub fn taskResponseFromRow(res: *zfinal.ResultSet, row: usize, workspace_id: []const u8) AgentTaskResponse {
    const r = &res.rows.items[row];
    const priority_text = r.getText(7) orelse "0";
    return AgentTaskResponse{
        .id = r.getText(0) orelse "",
        .agent_id = r.getText(1) orelse "",
        .runtime_id = r.getText(2),
        .issue_id = r.getText(3),
        .workspace_id = workspace_id,
        .chat_session_id = r.getText(5),
        .status = r.getText(6) orelse "queued",
        .priority = std.fmt.parseInt(i32, priority_text, 10) catch 0,
        .created_at = r.getText(19) orelse "",
        .updated_at = r.getText(20) orelse "",
    };
}

pub fn taskMessagePayloadFromEntry(entry: TaskMessageEntry, issue_id: ?[]const u8) TaskMessagePayload {
    return TaskMessagePayload{
        .task_id = entry.task_id,
        .issue_id = issue_id,
        .seq = entry.seq,
        .type = entry.type,
        .tool = entry.tool,
        .content = entry.content,
        .input = null,
        .output = entry.output,
        .created_at = entry.created_at,
    };
}

/// `res` is the result of `SELECT * FROM task_message ...`.
/// Column positions match the `task_message` schema.
pub fn taskMessagePayloadFromRow(res: *zfinal.ResultSet, row: usize, task_id: []const u8, issue_id: ?[]const u8) TaskMessagePayload {
    const r = &res.rows.items[row];
    const seq_text = r.getText(2) orelse "0";
    return TaskMessagePayload{
        .task_id = task_id,
        .issue_id = issue_id,
        .seq = std.fmt.parseInt(i32, seq_text, 10) catch 0,
        .type = r.getText(3) orelse "",
        .tool = r.getText(4),
        .content = r.getText(5),
        .input = null,
        .output = r.getText(7),
        .created_at = r.getText(8),
    };
}

/// Fetch the `issue_id` for a task scoped to its workspace. Returns
/// `null` when the task doesn't exist or doesn't belong to the given
/// workspace. The string is a fresh `allocator`-owned copy — the
/// caller is responsible for freeing it.
pub fn dbFetchTaskIssueId(allocator: std.mem.Allocator, task_id: []const u8, workspace_id: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT atq.issue_id FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id WHERE atq.id = $1::uuid AND a.workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = task_id },
            .{ .text = workspace_id },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const borrowed = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, borrowed);
}

/// `SELECT * FROM task_message WHERE task_id = $1 ORDER BY seq ASC`.
/// Returns `&[_]` (empty) when no DB is available so the caller can
/// still render an empty list.
pub fn dbListMessages(allocator: std.mem.Allocator, task_id: []const u8, issue_id: ?[]const u8) ![]TaskMessagePayload {
    const db = borrowDb() orelse return &[_]TaskMessagePayload{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT * FROM task_message WHERE task_id = $1::uuid ORDER BY seq ASC",
        &[_]SqlParam{.{ .text = task_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(TaskMessagePayload) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        try list.append(allocator, taskMessagePayloadFromRow(&rs, i, task_id, issue_id));
    }
    return try list.toOwnedSlice(allocator);
}

/// `UPDATE agent_task_queue SET status = 'cancelled', completed_at = now(), updated_at = now() WHERE id = $1 RETURNING *`.
/// Returns a borrowed ResultSet (caller owns / deinits) when the row
/// exists, or `null` when no row was updated. The ResultSet is owned
/// by the caller because the legacy code references `rs` after the
/// UPDATE completes (it dereferences into `rs.rows.items[0]` for
/// `taskResponseFromRow`).
pub fn dbCancelTask(task_id: []const u8) !?zfinal.ResultSet {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "UPDATE agent_task_queue SET status = 'cancelled', completed_at = now(), updated_at = now() WHERE id = $1::uuid RETURNING *",
        &[_]SqlParam{.{ .text = task_id }},
    );
    errdefer rs.deinit();
    if (rs.rows.items.len == 0) {
        rs.deinit();
        return null;
    }
    return rs;
}
