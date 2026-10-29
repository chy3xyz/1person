//! Daemon module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and any escape-hatch SQL helpers. `service.zig`
//! wraps this with the business logic + the in-memory daemon registry
//! and task queue passthroughs.
//!
//! The daemon module is the bridge between the Go backend's
//! DaemonAuth-gated API surface and zserver's per-process state. The
//! table layout (`workspace`, `agent_task_queue`, `issue`,
//! `chat_session`, `autopilot_run`) all use UUID PKs with TIMESTAMPTZ
//! columns that the ORM can't model cleanly, so all SQL goes through
//! `zfinal.SqlParam` via `deps.acquire()`. The in-memory fallback uses
//! the `DaemonEntry` struct defined here so the no-DB smoke-test path
//! stays deterministic.

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

/// In-memory `daemon_registry` row.
pub const DaemonEntry = struct {
    id: []const u8,
    runtime_id: []const u8,
    name: []const u8,
    last_seen_at: i64,
};

// ──────────────────────────────────────────────────────────────────────
// Request DTOs
// ──────────────────────────────────────────────────────────────────────

pub const PinTaskSessionRequest = struct {
    session_id: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
};

pub const DaemonRegisterRequest = struct {
    runtime_id: []const u8,
    name: ?[]const u8 = null,
    /// Version of the 1p CLI the daemon is running. Reported by the CLI
    /// at registration and stored on the runtime row's
    /// `metadata.cli_version`; the quick-create gate reads it from there.
    cli_version: ?[]const u8 = null,
};

pub const MintDaemonTokenRequest = struct {
    workspace_id: []const u8,
    ttl_days: ?i64 = null,
};

/// True when user_id is a member of workspace_id (any role). Used by
/// the daemon-token minting endpoint so only workspace members can mint
/// daemon credentials bound to that workspace.
pub fn userIsWorkspaceMember(user_id: []const u8, workspace_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT 1 FROM member WHERE workspace_id = $1::uuid AND user_id = $2::uuid LIMIT 1",
        &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// Flip an agent_runtime row's status (e.g. online/offline). Used by the
/// daemon register/deregister so runtimes the daemon serves show the
/// right liveness state (Go parity). Returns false in no-DB mode.
pub fn setRuntimeStatus(runtime_id: []const u8, status: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    db.execParams(
        "UPDATE agent_runtime SET status = $2 WHERE id = $1::uuid",
        &[_]SqlParam{ .{ .text = runtime_id }, .{ .text = status } },
    ) catch return false;
    return true;
}

/// Insert a minted daemon token (SHA-256 hash of the full 1d_ token)
/// into the daemon_token table. `owner_id` records the member who paired
/// the machine — it is what the runtime row inherits at registration.
/// Returns true on success.
pub fn insertDaemonToken(workspace_id: []const u8, daemon_id: []const u8, token_hash: []const u8, ttl_days: i64, owner_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    const sql =
        "INSERT INTO daemon_token (token_hash, workspace_id, daemon_id, owner_id, expires_at) " ++
        "VALUES ($1, $2::uuid, $3, $4::uuid, now() + make_interval(days => $5))";
    db.execParams(sql, &[_]SqlParam{
        .{ .text = token_hash },
        .{ .text = workspace_id },
        .{ .text = daemon_id },
        .{ .text = owner_id },
        .{ .int = ttl_days },
    }) catch return false;
    return true;
}

/// Register the runtime row a daemon serves.
///
/// Upstream parity: `server/internal/handler/daemon.go` upserts
/// `agent_runtime` at registration and writes `owner_id` with a
/// `required_owner_id` fence — a re-registering daemon must not steal a
/// row that already has an owner. The same fence is reproduced here:
/// `owner_id = COALESCE(agent_runtime.owner_id, EXCLUDED.owner_id)`
/// keeps the first owner and only fills in an ownerless row.
///
/// `workspace_id` is deliberately NOT updated on conflict: a runtime
/// belongs to exactly one workspace, and a daemon presenting a token
/// for another workspace must not be able to re-point somebody else's
/// row. The caller checks that case before calling this.
///
/// Returns false when the DB write fails.
pub fn upsertRuntimeForDaemon(
    runtime_id: []const u8,
    workspace_id: []const u8,
    owner_id: []const u8,
    name: []const u8,
) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    const sql =
        "INSERT INTO agent_runtime (id, workspace_id, name, runtime_mode, provider, status, owner_id, visibility) " ++
        "VALUES ($1::uuid, $2::uuid, $3, 'local', 'auto', 'online', $4::uuid, 'private') " ++
        "ON CONFLICT (id) DO UPDATE SET " ++
        "status = 'online', " ++
        "name = COALESCE(NULLIF(EXCLUDED.name, ''), agent_runtime.name), " ++
        "owner_id = COALESCE(agent_runtime.owner_id, EXCLUDED.owner_id), " ++
        "updated_at = now()";
    db.execParams(sql, &[_]SqlParam{
        .{ .text = runtime_id },
        .{ .text = workspace_id },
        .{ .text = name },
        // An empty owner means "this token predates the owner column".
        // Pass SQL NULL for it — an empty string is not a uuid and the
        // cast would abort the whole insert.
        if (owner_id.len > 0) SqlParam{ .text = owner_id } else SqlParam.null,
    }) catch return false;
    return true;
}

/// Read the workspace a runtime row belongs to. Returns null when no
/// row with that id exists.
///
/// The returned slice is owned by `allocator`: the result set frees its
/// own cell text on `deinit`, so handing that text to the caller would
/// leave it reading freed memory (zfinal's own history has a "UUUU
/// symptoms" bug report for exactly this shape).
pub fn runtimeWorkspaceId(allocator: std.mem.Allocator, runtime_id: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT workspace_id FROM agent_runtime WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = runtime_id }},
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

/// Read the owner of a workspace. Used as the fallback owner for a
/// daemon token minted before the owner column existed. The fork stores
/// the workspace owner in `member.role = 'owner'`, not on the workspace
/// row.
///
/// The returned slice is owned by `allocator` — see `runtimeWorkspaceId`.
pub fn workspaceOwnerId(allocator: std.mem.Allocator, workspace_id: []const u8) !?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT user_id::text FROM member " ++
        "WHERE workspace_id = $1::uuid AND role = 'owner' " ++
        "ORDER BY created_at LIMIT 1",
        &[_]SqlParam{.{ .text = workspace_id }},
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const text = rs.rows.items[0].getText(0) orelse return null;
    return try allocator.dupe(u8, text);
}

pub const TaskProgressRequest = struct {
    progress: ?i32 = null,
};

pub const TaskFailRequest = struct {
    @"error": ?[]const u8 = null,
};

pub const TaskUsageRequest = struct {
    usage: ?std.json.Value = null,
};

pub const TaskMessagesRequest = struct {
    messages: ?[]const []const u8 = null,
};

// ──────────────────────────────────────────────────────────────────────
// GC-check SQL helpers (DB mode)
// ──────────────────────────────────────────────────────────────────────

/// `SELECT repos FROM workspace WHERE id = $1::uuid` — returns the
/// workspace's `repos` JSON text. Caller renders a 404 if the row is
/// missing.
pub fn selectWorkspaceRepos(workspace_id: []const u8) ![]const u8 {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT repos FROM workspace WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = workspace_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.WorkspaceNotFound;
    return rs.rows.items[0].getText(0) orelse "[]";
}

/// `SELECT status, error FROM agent_task_queue WHERE id = $1::uuid` —
/// returns `(status, error)` for a task, or `error.TaskNotFound` when
/// the row is missing.
pub fn selectTaskStatus(task_id: []const u8) !struct { status: []const u8, @"error": ?[]const u8 } {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT status, error FROM agent_task_queue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = task_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.TaskNotFound;
    return .{
        .status = rs.rows.items[0].getText(0) orelse "",
        .@"error" = rs.rows.items[0].getText(1),
    };
}

/// `SELECT status, updated_at FROM issue WHERE id = $1::uuid`.
pub fn selectIssueGCCheck(issue_id: []const u8) !struct { status: []const u8, updated_at: ?[]const u8 } {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT status, updated_at FROM issue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = issue_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.IssueNotFound;
    return .{
        .status = rs.rows.items[0].getText(0) orelse "",
        .updated_at = rs.rows.items[0].getText(1),
    };
}

/// `SELECT status, updated_at FROM chat_session WHERE id = $1::uuid`.
pub fn selectChatSessionGCCheck(session_id: []const u8) !struct { status: []const u8, updated_at: ?[]const u8 } {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT status, updated_at FROM chat_session WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = session_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.ChatSessionNotFound;
    return .{
        .status = rs.rows.items[0].getText(0) orelse "",
        .updated_at = rs.rows.items[0].getText(1),
    };
}

/// `SELECT status, completed_at FROM autopilot_run WHERE id = $1::uuid`.
pub fn selectAutopilotRunGCCheck(run_id: []const u8) !struct { status: []const u8, completed_at: ?[]const u8 } {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT status, completed_at FROM autopilot_run WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = run_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.AutopilotRunNotFound;
    return .{
        .status = rs.rows.items[0].getText(0) orelse "",
        .completed_at = rs.rows.items[0].getText(1),
    };
}

/// `SELECT status FROM agent_task_queue WHERE id = $1::uuid` — used by
/// the task GC check. The status is the only field callers need.
pub fn selectTaskGCCheck(task_id: []const u8) ![]const u8 {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT status FROM agent_task_queue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = task_id }},
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.TaskNotFound;
    return rs.rows.items[0].getText(0) orelse "";
}

// ──────────────────────────────────────────────────────────────────────
// pinTaskSession SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// Pin a `session_id` to the given task. Best-effort: errors propagate
/// so the caller can render a 500.
pub fn pinSession(task_id: []const u8, session_id: []const u8) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    _ = try db.queryParams(
        "UPDATE agent_task_queue SET session_id = $1 WHERE id = $2::uuid",
        &[_]SqlParam{
            .{ .text = session_id },
            .{ .text = task_id },
        },
    );
}

/// Pin a `work_dir` to the given task.
pub fn pinWorkDir(task_id: []const u8, work_dir: []const u8) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    _ = try db.queryParams(
        "UPDATE agent_task_queue SET work_dir = $1 WHERE id = $2::uuid",
        &[_]SqlParam{
            .{ .text = work_dir },
            .{ .text = task_id },
        },
    );
}

/// Pin both `session_id` and `work_dir` atomically.
pub fn pinSessionAndWorkDir(task_id: []const u8, session_id: []const u8, work_dir: []const u8) !void {
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    _ = try db.queryParams(
        "UPDATE agent_task_queue SET session_id = $1, work_dir = $2 WHERE id = $3::uuid",
        &[_]SqlParam{
            .{ .text = session_id },
            .{ .text = work_dir },
            .{ .text = task_id },
        },
    );
}
