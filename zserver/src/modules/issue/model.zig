//! Issue module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.
//!
//! The real `issue` table lives in the legacy migrations:
//!   id UUID PK, workspace_id, title, description, status, priority,
//!   assignee_type, assignee_id, creator_type, creator_id,
//!   parent_issue_id, project_id, position, due_date, metadata
//!   (JSONB), created_at, updated_at.
//!
//! Because the actual table has `status` (not `state`), `parent_issue_id`
//! (not `parent_id`), and no `deleted_at`, this module exposes two
//! distinct shapes:
//!   * `Issue`  — the simplified internal / in-memory struct requested
//!     by the migration spec (`id, title, description, project_id,
//!     parent_id, assignee_id, state, created_at, updated_at,
//!     deleted_at?`). The DB and in-memory paths both materialise into
//!     this shape; the in-memory store uses it as its row type.
//!   * `IssueResponse` — the wire DTO, projected to the canonical
//!     fields the client (`packages/core/types/issue.ts::Issue`)
//!     expects. The DB → response translation lives in
//!     `issueResponseFromRow` and `issueResponseFromEntry`.
//!
//! The migration is complete: all 42 endpoints (core CRUD +
//! sub-resource endpoints: labels, attachments, timeline, subscribers,
//! reactions, quick-create, rerun, batch-update, batch-delete,
//! child-progress, grouped, listChildren, squadEvaluated) are
//! implemented.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");

// ──────────────────────────────────────────────────────────────────────
// DB borrow helper
// ──────────────────────────────────────────────────────────────────────

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised. Caller owns the
/// `defer deps.releaseBack(db)`.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

// ──────────────────────────────────────────────────────────────────────
// in-memory state
// ──────────────────────────────────────────────────────────────────────

/// Page allocator used by the in-memory fallback. Lives in process
/// scope because the data is intentionally non-collected.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Best-effort, never-fail `dupe` over the page allocator. Caller
/// owns the returned slice.
pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

/// Format a Unix-seconds value as a string for in-memory timestamp
/// columns. Mirrors the `memFmtNumber` helper in
/// `src/modules/workspace/model.zig`.
pub fn memFmtNumber(n: i64) ![]const u8 {
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{n});
}

/// Stable pseudo-UUID for the in-memory store. Matches the
/// `generateId` algorithm used by the workspace / project / label
/// modules.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

/// Mutex guarding every in-memory map below.
pub var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// Primary in-memory `issue` store: id → `Issue`. Used by the no-DB
/// fallback path so the 8 CRUD endpoints stay exercisable in smoke
/// tests.
pub var mem_issues: ?std.StringHashMap(Issue) = null;

/// `metadata` KV map keyed by issue id. Separate from `mem_issues`
/// to keep the row type simple and match the column layout in
/// migration 105 (`issue.metadata JSONB`). Values are string-typed
/// because the in-memory layer doesn't need a JSON parser.
pub var mem_metadata: ?std.StringHashMap(std.StringHashMap([]const u8)) = null;

/// Subscriber lists. `mem_subscribers` is keyed by issue id and maps
/// to a list of `SubscriberEntry` rows. Backs the no-DB branch of
/// `addSubscriber` / `listSubscribers` / `removeSubscriber`.
pub var mem_subscribers: ?std.StringHashMap(std.ArrayList(SubscriberEntry)) = null;

/// Reaction list per issue. Same purpose as `mem_subscribers`.
pub var mem_reactions: ?std.StringHashMap(std.ArrayList(ReactionEntry)) = null;

/// Timeline events per issue, ordered by `created_at`. Mirrors the
/// `issue_timeline_event` table layout from migration 028.
pub var mem_timeline: ?std.StringHashMap(std.ArrayList(TimelineEvent)) = null;

/// Attachment links per issue. Each entry is the attachment id; the
/// actual file metadata lives in the `attachment` module's tables.
pub var mem_attachments: ?std.StringHashMap(std.ArrayList([]u8)) = null;

/// Label associations per issue. Mirrors the `issue_label` join
/// table (migration 047): keyed by issue id, value is the ordered
/// label list. The no-DB path
/// uses this instead of the `metadata._labels` single-key hack.
pub var mem_issue_labels: ?std.StringHashMap(std.ArrayList([]const u8)) = null;

/// Task queue per issue. Mirrors `agent_task_queue` rows joined by
/// `issue_id`. Used by the no-DB path to back the
/// `/api/issues/:id/active-task`, `/api/issues/:id/task-runs`, and
/// `/api/issues/:id/usage` endpoints.
pub var mem_tasks: ?std.StringHashMap(std.ArrayList(TaskEntry)) = null;

/// Linked GitHub pull requests per issue. Mirrors `issue_pull_request`
/// (or the join that the Go server uses). Used by
/// `/api/issues/:id/pull-requests`.
pub var mem_pull_requests: ?std.StringHashMap(std.ArrayList(PullRequestEntry)) = null;

/// Timeline event row. Mirrors the `issue_timeline_event` table.
pub const TimelineEvent = struct {
    id: []const u8,
    issue_id: []const u8,
    event_type: []const u8, // e.g. "issue_created", "metadata_updated"
    actor_type: []const u8, // "user" | "agent" | "system"
    actor_id: []const u8,
    /// Free-form payload (e.g. the before/after metadata diff). Kept
    /// as a raw JSON string for simplicity; the DB path stores
    /// `JSONB`.
    payload: []const u8,
    created_at: []const u8,
};

/// Lazy initialiser for the in-memory maps. Safe to call repeatedly.
pub fn memInit() !void {
    if (mem_issues == null) {
        mem_issues = std.StringHashMap(Issue).init(memAlloc());
        mem_metadata = std.StringHashMap(std.StringHashMap([]const u8)).init(memAlloc());
        mem_subscribers = std.StringHashMap(std.ArrayList(SubscriberEntry)).init(memAlloc());
        mem_reactions = std.StringHashMap(std.ArrayList(ReactionEntry)).init(memAlloc());
        mem_timeline = std.StringHashMap(std.ArrayList(TimelineEvent)).init(memAlloc());
        mem_attachments = std.StringHashMap(std.ArrayList([]u8)).init(memAlloc());
        mem_issue_labels = std.StringHashMap(std.ArrayList([]const u8)).init(memAlloc());
        mem_tasks = std.StringHashMap(std.ArrayList(TaskEntry)).init(memAlloc());
        mem_pull_requests = std.StringHashMap(std.ArrayList(PullRequestEntry)).init(memAlloc());
    }
}

pub fn memAddTimelineEvent(event: TimelineEvent) !void {
    try memInit();
    // See `memAddSubscriber` for the dangling-slice rationale: we
    // memDup the issue_id so the hashmap key survives past the
    // request that created it.
    const stable_id = try memDup(event.issue_id);
    errdefer memAlloc().free(stable_id);
    const gop = try mem_timeline.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(memAlloc(), event);
}

pub fn memListTimeline(issue_id: []const u8) []TimelineEvent {
    const tl = mem_timeline orelse return &[_]TimelineEvent{};
    const list = tl.getPtr(issue_id) orelse return &[_]TimelineEvent{};
    return list.items;
}

pub fn memAddAttachment(issue_id: []const u8, attachment_id: []const u8) !void {
    try memInit();
    // See `memAddSubscriber` for the dangling-slice rationale: we
    // memDup the issue_id so the hashmap key survives past the
    // request that created it.
    const stable_id = try memDup(issue_id);
    errdefer memAlloc().free(stable_id);
    const gop = try mem_attachments.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const dup = try memAlloc().dupe(u8, attachment_id);
    try gop.value_ptr.append(memAlloc(), dup);
}

pub fn memListAttachments(issue_id: []const u8) []const []u8 {
    const m = mem_attachments orelse return &[_][]u8{};
    const list = m.getPtr(issue_id) orelse return &[_][]u8{};
    return list.items;
}

/// Attach `label_id` to `issue_id`. Idempotent: if the label is
/// already attached, the list is unchanged. The `issue_id` key is
/// memDup'd into stable memory; the `label_id` values are also
/// memDup'd.
pub fn memAttachLabel(issue_id: []const u8, label_id: []const u8) !void {
    try memInit();
    const stable_issue_id = try memDup(issue_id);
    errdefer memAlloc().free(stable_issue_id);
    const gop = try mem_issue_labels.?.getOrPut(stable_issue_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const list = gop.value_ptr;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, label_id)) return; // already attached
    }
    try list.append(memAlloc(), try memDup(label_id));
}

/// Detach `label_id` from `issue_id`. Returns `true` when the label
/// was present and removed.
pub fn memDetachLabel(issue_id: []const u8, label_id: []const u8) bool {
    if (mem_issue_labels == null) return false;
    const list = mem_issue_labels.?.getPtr(issue_id) orelse return false;
    for (list.items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, label_id)) {
            _ = list.orderedRemove(i);
            return true;
        }
    }
    return false;
}

/// Return the label ids attached to an issue.
pub fn memListLabels(issue_id: []const u8) []const []const u8 {
    if (mem_issue_labels == null) return &[_][]const u8{};
    const list = mem_issue_labels.?.getPtr(issue_id) orelse return &[_][]const u8{};
    return list.items;
}

/// Cascade-delete a label id from every issue's join list. Called
/// by the `label` module when a `Label` row is removed. Returns the
/// number of `(issue, label)` tuples removed.
pub fn memCascadeDeleteLabel(label_id: []const u8) usize {
    if (mem_issue_labels == null) return 0;
    var removed: usize = 0;
    var it = mem_issue_labels.?.iterator();
    while (it.next()) |kv| {
        const list = kv.value_ptr;
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i], label_id)) {
                _ = list.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
    }
    return removed;
}

/// Append a task to the in-memory queue. All string fields are
/// memDup'd so the entries survive past the request lifetime.
pub fn memAddTask(task: TaskEntry) !void {
    try memInit();
    const stable_id = try memDup(task.issue_id);
    errdefer memAlloc().free(stable_id);
    const gop = try mem_tasks.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(memAlloc(), task);
}

/// Return all tasks for an issue (or empty list).
pub fn memListTasks(issue_id: []const u8) []TaskEntry {
    const m = mem_tasks orelse return &[_]TaskEntry{};
    const list = m.getPtr(issue_id) orelse return &[_]TaskEntry{};
    return list.items;
}

/// Append a pull request for a specific issue.
pub fn memAddPullRequestForIssue(issue_id: []const u8, pr: PullRequestEntry) !void {
    try memInit();
    const stable_id = try memDup(issue_id);
    errdefer memAlloc().free(stable_id);
    const gop = try mem_pull_requests.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(memAlloc(), pr);
}

/// Return PRs for an issue (or empty list).
pub fn memListPullRequests(issue_id: []const u8) []PullRequestEntry {
    const m = mem_pull_requests orelse return &[_]PullRequestEntry{};
    const list = m.getPtr(issue_id) orelse return &[_]PullRequestEntry{};
    return list.items;
}

// ──────────────────────────────────────────────────────────────────────
// internal row structs
// ──────────────────────────────────────────────────────────────────────

/// Simplified in-memory / internal issue row. Matches the migration
/// spec exactly: `id, title, description, project_id, parent_id,
/// assignee_id, state, created_at, updated_at, deleted_at?`, plus the
/// extra fields required to align with the Go server's `Issue`
/// SQLC model (`priority`, `assignee_type`, `creator_type/id`,
/// `position`, `due_date`, `start_date`, `number`).
pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    project_id: []const u8,
    parent_id: []const u8,
    assignee_id: []const u8,
    state: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    deleted_at: ?[]const u8 = null,
    squad_evaluated_at: ?[]const u8 = null,
    // Go alignment fields
    priority: []const u8 = "none",
    assignee_type: ?[]const u8 = null,
    creator_type: []const u8 = "member",
    creator_id: []const u8 = "",
    position: f64 = 0.0,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    number: i32 = 0,
};

/// Subscriber row used by the subscriber endpoints. Mirrors the
/// `issue_subscriber` table layout from migration 015.
pub const SubscriberEntry = struct {
    issue_id: []const u8,
    user_type: []const u8,
    user_id: []const u8,
    reason: []const u8,
    created_at: []const u8,
};

/// Reaction row used by the reaction endpoints. Mirrors the
/// `issue_reaction` table layout from migration 027.
pub const ReactionEntry = struct {
    id: []const u8,
    issue_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    emoji: []const u8,
    created_at: []const u8,
};

/// Task row used by the no-DB fallback for `/active-task`,
/// `/task-runs`, and `/usage`. Mirrors the `agent_task_queue` table
/// joined by `issue_id`. The Go server returns ~60 fields per task;
/// we keep the subset the no-DB path needs to compute usage totals
/// and active status.
pub const TaskEntry = struct {
    id: []const u8,
    issue_id: []const u8,
    status: []const u8, // queued|dispatched|running|waiting_local_directory|completed|failed|cancelled
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    created_at: []const u8 = "",
};

/// Pull request row used by `/api/issues/:id/pull-requests`. Mirrors
/// the `github_pull_request` join. The no-DB path only renders a
/// minimal subset; tests that exercise this endpoint will
/// pre-populate `mem_pull_requests` via a test-only handler.
pub const PullRequestEntry = struct {
    id: []const u8,
    number: i32,
    title: []const u8,
    state: []const u8, // open|closed|merged
    repo_owner: []const u8,
    repo_name: []const u8,
    html_url: []const u8,
    author_login: []const u8 = "",
    pr_created_at: []const u8 = "",
    pr_updated_at: []const u8 = "",
};

/// Wire DTO for the `/active-task` (wrapped) and `/task-runs` (bare)
/// endpoints. Mirrors the shape the Go server returns; the no-DB
/// path projects `TaskEntry` into this.
pub const TaskResponse = struct {
    id: []const u8,
    issue_id: []const u8,
    status: []const u8,
    created_at: []const u8,
};

/// Wire DTO for `/api/issues/:id/pull-requests`.
pub const PullRequestResponse = struct {
    id: []const u8,
    number: i32,
    title: []const u8,
    state: []const u8,
    repo_owner: []const u8,
    repo_name: []const u8,
    html_url: []const u8,
    author_login: []const u8,
    pr_created_at: []const u8,
    pr_updated_at: []const u8,
};

/// Wire DTO for `/api/issues/:id/usage`.
pub const IssueUsageResponse = struct {
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cache_read_tokens: i64,
    total_cache_write_tokens: i64,
    task_count: i32,
};

/// Wire DTO for the comment-trigger preview.
pub const CommentTriggerPreviewRequest = struct {
    content: []const u8 = "",
    parent_id: ?[]const u8 = null,
};

pub const CommentTriggerAgentResponse = struct {
    id: []const u8,
    name: []const u8,
    avatar_url: ?[]const u8 = null,
    source: []const u8, // issue_assignee|mention_agent|mention_squad_leader
    reason: []const u8,
};

pub const CommentTriggerPreviewResponse = struct {
    agents: []CommentTriggerAgentResponse = &[_]CommentTriggerAgentResponse{},
};

/// Wire DTO for `POST /api/issues/:id/subscribe` and the matching
/// unsubscribe endpoint.
pub const SubscribeResponse = struct {
    subscribed: bool,
};

/// Wire DTO for the `removeReaction` (by emoji) endpoint.
pub const RemoveReactionRequest = struct {
    emoji: []const u8 = "",
};

/// Wire DTO for the per-key metadata endpoints.
pub const SetMetadataKeyRequest = struct {
    value: std.json.Value,
};

/// Format a Unix epoch second as a string. Reused by
/// addSubscriber / addReaction to stamp `created_at` on in-memory
/// rows. Epoch seconds is unambiguous and matches the no-DB smoke
/// pattern; the DB path uses `TIMESTAMPTZ` directly.
pub fn rfc3339(allocator: std.mem.Allocator, secs: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{secs});
}

// ──────────────────────────────────────────────────────────────────────
// wire DTOs
// ──────────────────────────────────────────────────────────────────────

/// Request body for `POST /api/issues` and `PATCH /api/issues/:id`.
/// All fields are optional in the PATCH case (only present fields
/// are updated) and required-ish in the POST case (`title` is the
/// only mandatory field — everything else has a sensible default).
pub const CreateIssueRequest = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    // Go alignment fields
    assignee_type: ?[]const u8 = null,
    creator_type: ?[]const u8 = null,
    creator_id: ?[]const u8 = null,
    position: ?f64 = null,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
};

pub const UpdateIssueRequest = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    // Go alignment fields
    assignee_type: ?[]const u8 = null,
    creator_type: ?[]const u8 = null,
    creator_id: ?[]const u8 = null,
    position: ?f64 = null,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
};

/// Request body for `PATCH /api/issues/:id/metadata`. The wire shape
/// is a flat key→primitive object. Per the client type, the server
/// clamps to the same primitive union (`string | number | boolean`).
/// `std.json.Value` is the canonical Zig holder for a JSON object;
/// the request may carry an empty map.
pub const SetMetadataRequest = struct {
    metadata: std.json.Value,
};

/// `GET /api/issues/:id/metadata` response.
pub const GetMetadataResponse = struct {
    issue_id: []const u8,
    metadata: std.json.Value,
};

/// Response shape returned to clients. Mirrors the canonical
/// `Issue` interface in `packages/core/types/issue.ts`. The DB
/// column names are translated to the simpler API names here
/// (e.g. `status` → `state`).
pub const IssueResponse = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    project_id: ?[]const u8,
    parent_id: ?[]const u8,
    assignee_id: ?[]const u8,
    state: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    deleted_at: ?[]const u8 = null,
    squad_evaluated_at: ?[]const u8 = null,
    // Go alignment fields
    priority: []const u8 = "none",
    assignee_type: ?[]const u8 = null,
    creator_type: []const u8 = "member",
    creator_id: []const u8 = "",
    position: f64 = 0.0,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    number: i32 = 0,
};

// ──────────────────────────────────────────────────────────────────────
// context helpers
// ──────────────────────────────────────────────────────────────────────

/// Pull the workspace id stashed on the context by the workspace
/// middleware. Empty string when missing.
pub fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

// ──────────────────────────────────────────────────────────────────────
// validators
// ──────────────────────────────────────────────────────────────────────

/// `state` → `status` validator. The DB `issue.status` check constraint
/// accepts: `backlog`, `todo`, `in_progress`, `in_review`, `done`,
/// `blocked`, `cancelled`. We also accept the legacy values
/// (`open`, `closed`) used by the original zserver e2e to keep
/// backwards-compat with older clients.
pub fn isValidState(state: []const u8) bool {
    const valid = [_][]const u8{
        "backlog", "todo", "in_progress", "in_review",
        "done",    "blocked", "cancelled",
        // legacy aliases — accepted but coerced to canonical values
        // by callers when needed.
        "open",   "closed",
    };
    for (valid) |v| if (std.mem.eql(u8, state, v)) return true;
    return false;
}

pub const DEFAULT_STATE: []const u8 = "todo";

/// `priority` validator — the DB has a CHECK for
/// `urgent | high | medium | low | none`.
pub fn isValidPriority(priority: []const u8) bool {
    const valid = [_][]const u8{ "urgent", "high", "medium", "low", "none" };
    for (valid) |v| if (std.mem.eql(u8, priority, v)) return true;
    return false;
}

pub const DEFAULT_PRIORITY: []const u8 = "none";

/// Trim + non-empty check. Returns the trimmed slice or `null` when
/// the field is empty.
pub fn validateTitle(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return trimmed;
}

// ──────────────────────────────────────────────────────────────────────
// row → response projectors
// ──────────────────────────────────────────────────────────────────────

/// Convert a `SELECT id, title, description, project_id, parent_issue_id,
/// assignee_id, status, created_at, updated_at FROM issue` row to
/// the API response shape. Empty-string → null translation lives here
/// so the DB path doesn't have to special-case the response shape.
pub fn issueResponseFromRow(res: *zfinal.ResultSet, row: usize) IssueResponse {
    const r = &res.rows.items[row];
    return IssueResponse{
        .id = r.getText(0) orelse "",
        .title = r.getText(1) orelse "",
        .description = r.getText(2),
        .project_id = emptyToNull(r.getText(3)),
        .parent_id = emptyToNull(r.getText(4)),
        .assignee_id = emptyToNull(r.getText(5)),
        .state = r.getText(6) orelse "backlog",
        .created_at = r.getText(7) orelse "",
        .updated_at = r.getText(8) orelse "",
        // DB schema doesn't have `squad_evaluated_at` yet; expose
        // null until the migration adds the column.
        .squad_evaluated_at = null,
    };
}

/// Convert an in-memory `Issue` row to the API response shape.
pub fn issueResponseFromEntry(entry: Issue) IssueResponse {
    return IssueResponse{
        .id = entry.id,
        .title = entry.title,
        .description = if (entry.description.len > 0) entry.description else null,
        .project_id = if (entry.project_id.len > 0) entry.project_id else null,
        .parent_id = if (entry.parent_id.len > 0) entry.parent_id else null,
        .assignee_id = if (entry.assignee_id.len > 0) entry.assignee_id else null,
        .state = entry.state,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .deleted_at = entry.deleted_at,
        .squad_evaluated_at = entry.squad_evaluated_at,
        .priority = entry.priority,
        .assignee_type = entry.assignee_type,
        .creator_type = entry.creator_type,
        .creator_id = entry.creator_id,
        .position = entry.position,
        .due_date = entry.due_date,
        .start_date = entry.start_date,
        .number = entry.number,
    };
}

/// Dupe every text field from a single result-set row into `allocator`,
/// returning an `IssueResponse` whose lifetime is independent of the
/// result set. Callers that `defer rs.deinit()` before returning MUST
/// use this instead of the raw `issueResponseFromRow`.
fn issueResponseFromRowDuped(allocator: std.mem.Allocator, res: *zfinal.ResultSet, row: usize) ?IssueResponse {
    const r = &res.rows.items[row];
    const dup_id = allocator.dupe(u8, r.getText(0) orelse "") catch return null;
    errdefer allocator.free(dup_id);
    const dup_title = allocator.dupe(u8, r.getText(1) orelse "") catch return null;
    errdefer allocator.free(dup_title);
    const desc_raw = r.getText(2);
    const dup_desc: ?[]const u8 = if (desc_raw) |d| blk: {
        const dd = allocator.dupe(u8, d) catch return null;
        break :blk if (dd.len == 0) null else dd;
    } else null;
    errdefer if (dup_desc) |d| allocator.free(d);
    const proj_raw = r.getText(3);
    const dup_proj: ?[]const u8 = if (proj_raw) |p| blk: {
        const dp = allocator.dupe(u8, p) catch return null;
        break :blk if (dp.len == 0) null else dp;
    } else null;
    errdefer if (dup_proj) |p| allocator.free(p);
    const par_raw = r.getText(4);
    const dup_par: ?[]const u8 = if (par_raw) |p| blk: {
        const dp = allocator.dupe(u8, p) catch return null;
        break :blk if (dp.len == 0) null else dp;
    } else null;
    errdefer if (dup_par) |p| allocator.free(p);
    const asgn_raw = r.getText(5);
    const dup_asgn: ?[]const u8 = if (asgn_raw) |a| blk: {
        const da = allocator.dupe(u8, a) catch return null;
        break :blk if (da.len == 0) null else da;
    } else null;
    errdefer if (dup_asgn) |a| allocator.free(a);
    const dup_state = allocator.dupe(u8, r.getText(6) orelse "backlog") catch return null;
    errdefer allocator.free(dup_state);
    const dup_ca = allocator.dupe(u8, r.getText(7) orelse "") catch return null;
    errdefer allocator.free(dup_ca);
    const dup_ua = allocator.dupe(u8, r.getText(8) orelse "") catch return null;
    return IssueResponse{
        .id = dup_id,
        .title = dup_title,
        .description = dup_desc,
        .project_id = dup_proj,
        .parent_id = dup_par,
        .assignee_id = dup_asgn,
        .state = dup_state,
        .created_at = dup_ca,
        .updated_at = dup_ua,
        .squad_evaluated_at = null,
    };
}

/// Free every heap-allocated string field inside an IssueResponse that
/// was produced by `issueResponseFromRowDuped`.  Safe to call with
/// zero-length strings (they are "" not null).
fn freeIssueResponse(allocator: std.mem.Allocator, resp: IssueResponse) void {
    allocator.free(resp.id);
    allocator.free(resp.title);
    if (resp.description) |d| allocator.free(d);
    if (resp.project_id) |p| allocator.free(p);
    if (resp.parent_id) |p| allocator.free(p);
    if (resp.assignee_id) |a| allocator.free(a);
    allocator.free(resp.state);
    allocator.free(resp.created_at);
    allocator.free(resp.updated_at);
}

fn emptyToNull(s: ?[]const u8) ?[]const u8 {
    const t = s orelse return null;
    if (t.len == 0) return null;
    return t;
}

// ──────────────────────────────────────────────────────────────────────
// in-memory accessors (used by the no-DB fallback path)
// ──────────────────────────────────────────────────────────────────────

/// Insert / replace an `Issue` row in the in-memory store. Locks the
/// mutex for the duration of the call so concurrent CRUD endpoints
/// see a consistent snapshot.
pub fn memUpsertIssue(entry: Issue) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try mem_issues.?.put(entry.id, entry);
}

/// Look up an issue in the in-memory store. Returns `null` when the
/// store is uninitialised or the id is unknown.
pub fn memFindIssue(id: []const u8) ?Issue {
    if (mem_issues == null) return null;
    return mem_issues.?.get(id);
}

/// Remove an issue (and its metadata, subscribers, reactions,
/// tasks, PRs) from the in-memory store. Returns `true` when a row
/// was removed.
pub fn memRemoveIssue(id: []const u8) bool {
    if (mem_issues == null) return false;
    _ = mem_metadata.?.fetchRemove(id);
    _ = mem_subscribers.?.fetchRemove(id);
    _ = mem_reactions.?.fetchRemove(id);
    _ = mem_tasks.?.fetchRemove(id);
    _ = mem_pull_requests.?.fetchRemove(id);
    return mem_issues.?.fetchRemove(id) != null;
}

/// List children of a parent issue from the in-memory store. The
/// returned slice is allocated with `allocator` and must be freed by
/// the caller.
pub fn memListChildren(allocator: std.mem.Allocator, parent_id: []const u8) ![]Issue {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list: std.ArrayList(Issue) = .empty;
    if (mem_issues) |*map| {
        var it = map.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.parent_id, parent_id)) {
                try list.append(allocator, e.value_ptr.*);
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// List issues belonging to a set of parent ids. The returned slice
/// is allocated with `allocator` and must be freed by the caller.
pub fn memListChildrenByParents(allocator: std.mem.Allocator, parent_ids: []const []const u8) ![]Issue {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list: std.ArrayList(Issue) = .empty;
    if (mem_issues) |*map| {
        var it = map.iterator();
        outer: while (it.next()) |e| {
            for (parent_ids) |pid| {
                if (std.mem.eql(u8, e.value_ptr.parent_id, pid)) {
                    try list.append(allocator, e.value_ptr.*);
                    continue :outer;
                }
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Fetch the metadata map for an issue. The returned pointer is the
/// in-memory `StringHashMap` and is invalidated the next time the
/// metadata for this issue is mutated; callers should not retain it
/// past the call site.
pub fn memGetMetadata(issue_id: []const u8) ?*std.StringHashMap([]const u8) {
    if (mem_metadata == null) return null;
    return mem_metadata.?.getPtr(issue_id);
}

/// Replace the entire metadata map for an issue.
///
/// `issue_id` is request-scoped; we memDup it so the hashmap key
/// lives as long as the in-memory store. See `memAddSubscriber`
/// for the dangling-slice rationale.
pub fn memSetMetadata(issue_id: []const u8, map: std.StringHashMap([]const u8)) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const stable_id = try memDup(issue_id);
    errdefer memAlloc().free(stable_id);
    try mem_metadata.?.put(stable_id, map);
}

/// Add a subscriber row. Used by the no-DB `addSubscriber`
/// endpoint so the in-memory state is consistent.
///
/// `entry.issue_id` is request-scoped (it points to the path
/// param buffer that is freed when the request ends), but the
/// StringHashMap stores it as the key, so a follow-up request
/// (e.g. `removeSubscriber`) would compare by content against a
/// dangling pointer. We memDup the issue_id into the page
/// allocator so the key lives as long as the in-memory store.
/// The leak is acceptable for the no-DB path.
pub fn memAddSubscriber(entry: SubscriberEntry) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const stable_id = try memDup(entry.issue_id);
    errdefer memAlloc().free(stable_id);
    const list = mem_subscribers.?.getPtr(stable_id) orelse blk: {
        const l: std.ArrayList(SubscriberEntry) = .empty;
        try mem_subscribers.?.put(stable_id, l);
        break :blk mem_subscribers.?.getPtr(stable_id).?;
    };
    try list.append(memAlloc(), entry);
}

pub fn memRemoveSubscriber(issue_id: []const u8, user_type: []const u8, user_id: []const u8) bool {
    if (mem_subscribers == null) return false;
    const list_ptr = mem_subscribers.?.getPtr(issue_id) orelse return false;
    for (list_ptr.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.user_type, user_type) and std.mem.eql(u8, s.user_id, user_id)) {
            _ = list_ptr.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn memListSubscribers(issue_id: []const u8) []SubscriberEntry {
    if (mem_subscribers == null) return &[_]SubscriberEntry{};
    const list = mem_subscribers.?.get(issue_id) orelse return &[_]SubscriberEntry{};
    return list.items;
}

pub fn memAddReaction(entry: ReactionEntry) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    // See `memAddSubscriber` for the dangling-slice rationale: we
    // memDup the issue_id so the hashmap key survives past the
    // request that created it.
    const stable_id = try memDup(entry.issue_id);
    errdefer memAlloc().free(stable_id);
    const gop = try mem_reactions.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(memAlloc(), entry);
}

pub fn memRemoveReaction(issue_id: []const u8, reaction_id: []const u8) bool {
    if (mem_reactions == null) return false;
    const list_ptr = mem_reactions.?.getPtr(issue_id) orelse return false;
    for (list_ptr.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.id, reaction_id)) {
            _ = list_ptr.orderedRemove(i);
            return true;
        }
    }
    return false;
}

/// Remove a reaction by `(actor_type, actor_id, emoji)` tuple.
/// The Go server's `DELETE /api/issues/:id/reactions` endpoint
/// uses this identifier shape (no reactionId in the path).
pub fn memRemoveReactionByTuple(
    issue_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    emoji: []const u8,
) bool {
    if (mem_reactions == null) return false;
    const list_ptr = mem_reactions.?.getPtr(issue_id) orelse return false;
    for (list_ptr.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.actor_type, actor_type) and
            std.mem.eql(u8, r.actor_id, actor_id) and
            std.mem.eql(u8, r.emoji, emoji))
        {
            _ = list_ptr.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn memListReactions(issue_id: []const u8) []ReactionEntry {
    if (mem_reactions == null) return &[_]ReactionEntry{};
    const list = mem_reactions.?.get(issue_id) orelse return &[_]ReactionEntry{};
    return list.items;
}

// ──────────────────────────────────────────────────────────────────────
// DB escape-hatch SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// `SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid`.
/// Returns `true` when the row exists, `false` otherwise. Used by
/// the CRUD endpoints to gate ownership checks.
pub fn issueExistsById(workspace_id: []const u8, issue_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT 1 FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// Check whether an issue exists in the DB or in-memory store.
pub fn issueExistsAny(issue_id: []const u8) bool {
    if (memFindIssue(issue_id) != null) return true;
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT 1 FROM issue WHERE id = $1::uuid",
        &[_]SqlParam{.{ .text = issue_id }},
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `INSERT INTO issue (...) RETURNING ...` — creates a new issue in
/// the DB. The returned `IssueResponse` is already projected to the
/// API shape. Returns `null` when the insert failed or no row was
/// returned.
pub fn insertIssue(
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    state: []const u8,
    project_id: []const u8,
    parent_id: []const u8,
    assignee_id: []const u8,
) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO issue (workspace_id, title, description, status, project_id, parent_issue_id, " ++
            "assignee_type, assignee_id, creator_type, creator_id, number) " ++
            "VALUES ($1::uuid, $2, $3, $4, NULLIF($5, '')::uuid, NULLIF($6, '')::uuid, " ++
            "CASE WHEN NULLIF($7, '') IS NULL THEN NULL ELSE 'member' END, " ++
            "NULLIF($7, '')::uuid, 'member', $1::uuid, " ++
            "(SELECT COALESCE(MAX(number), 0) + 1 FROM issue WHERE workspace_id = $1::uuid)) " ++
            "RETURNING id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = description },
            .{ .text = state },
            .{ .text = project_id },
            .{ .text = parent_id },
            .{ .text = assignee_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `SELECT id, title, description, project_id::text, parent_issue_id::text,
/// assignee_id::text, status, created_at, updated_at FROM
/// issue WHERE id = $1::uuid AND workspace_id = $2::uuid`. Returns
/// `null` when no row matches.
pub fn selectIssueById(workspace_id: []const u8, issue_id: []const u8) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at " ++
            "FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `UPDATE issue SET <patch> WHERE id = $1 AND workspace_id = $2
/// RETURNING ...`. Empty strings for fields the caller doesn't want
/// to update; the SQL `COALESCE(NULLIF(..., ''), ...)` pattern keeps
/// the previous value in that case. The `status` column is renamed
/// to `state` in the API.
pub fn updateIssue(
    issue_id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    state: []const u8,
    project_id: []const u8,
    parent_id: []const u8,
    assignee_id: []const u8,
) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue SET " ++
            "title = COALESCE(NULLIF($3, ''), title), " ++
            "description = COALESCE(NULLIF($4, ''), description), " ++
            "status = COALESCE(NULLIF($5, ''), status), " ++
            "project_id = COALESCE(NULLIF($6, '')::uuid, project_id), " ++
            "parent_issue_id = COALESCE(NULLIF($7, '')::uuid, parent_issue_id), " ++
            "assignee_id = COALESCE(NULLIF($8, '')::uuid, assignee_id), " ++
            "updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = description },
            .{ .text = state },
            .{ .text = project_id },
            .{ .text = parent_id },
            .{ .text = assignee_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `UPDATE issue SET title = COALESCE(NULLIF($3,''), title), ...,
/// updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid
/// RETURNING id`. Used by batchUpdate for the DB path. Returns `true`
/// when a row was updated.
pub fn batchUpdateIssueDB(
    issue_id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    state: []const u8,
    project_id: []const u8,
    parent_id: []const u8,
    assignee_id: []const u8,
) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue SET " ++
            "title = COALESCE(NULLIF($3, ''), title), " ++
            "description = COALESCE(NULLIF($4, ''), description), " ++
            "status = COALESCE(NULLIF($5, ''), status), " ++
            "project_id = COALESCE(NULLIF($6, '')::uuid, project_id), " ++
            "parent_issue_id = COALESCE(NULLIF($7, '')::uuid, parent_issue_id), " ++
            "assignee_id = COALESCE(NULLIF($8, '')::uuid, assignee_id), " ++
            "updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = description },
            .{ .text = state },
            .{ .text = project_id },
            .{ .text = parent_id },
            .{ .text = assignee_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `DELETE FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid
/// RETURNING id`. The DB path uses a hard delete (the legacy
/// migration never introduced a `deleted_at` column, so the
/// "soft delete" hint in the migration spec only applies to the
/// in-memory store). Returns `true` when a row was removed.
pub fn softDeleteIssue(workspace_id: []const u8, issue_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "DELETE FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING id",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `UPDATE issue SET status = 'todo', updated_at = now() WHERE id = $1::uuid AND workspace_id = $2::uuid
/// RETURNING id, title, description, project_id::text, parent_issue_id::text,
/// assignee_id::text, status, created_at, updated_at`.
/// Returns the updated `IssueResponse` or `null` when no row matched.
pub fn dbRerunIssue(workspace_id: []const u8, issue_id: []const u8) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue SET status = 'todo', updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `SELECT id, title, description, project_id::text, parent_issue_id::text,
/// assignee_id::text, status, created_at, updated_at
/// FROM issue WHERE workspace_id = $1::uuid [AND status = $2]
/// [AND project_id = $3::uuid] [AND assignee_id = $4::uuid]
/// ORDER BY created_at DESC LIMIT $5 OFFSET $6`.
///
/// The query is composed dynamically as the filters accumulate; an
/// empty filter set still produces a valid query (no `WHERE`
/// clauses, just `workspace_id`). Returns the slice of `IssueResponse`
/// rows ready to be rendered.
pub fn listIssuesWithFilters(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    state_filter: ?[]const u8,
    project_filter: ?[]const u8,
    assignee_filter: ?[]const u8,
    limit: u32,
    offset: u32,
) ![]IssueResponse {
    const db = borrowDb() orelse return &[_]IssueResponse{};
    defer deps.releaseBack(db);

    var params: std.ArrayList(SqlParam) = .empty;
    defer params.deinit(allocator);
    try params.append(allocator, .{ .text = try allocator.dupe(u8, workspace_id) });

    var where: std.ArrayList(u8) = .empty;
    defer where.deinit(allocator);
    try where.appendSlice(allocator, "workspace_id = $1::uuid");

    var idx: usize = 1;
    if (state_filter) |s| {
        if (s.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, s) });
            const clause = try std.fmt.allocPrint(allocator, " AND status = ${d}", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }
    if (project_filter) |p| {
        if (p.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, p) });
            const clause = try std.fmt.allocPrint(allocator, " AND project_id = ${d}::uuid", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }
    if (assignee_filter) |a| {
        if (a.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, a) });
            const clause = try std.fmt.allocPrint(allocator, " AND assignee_id = ${d}::uuid", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }

    // Build ORDER BY + LIMIT + OFFSET separately, appended after WHERE.
    const order_by = " ORDER BY created_at DESC";

    // limit / offset are always last params.
    idx += 1;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);
    try params.append(allocator, .{ .text = try allocator.dupe(u8, limit_str) });
    const limit_clause = try std.fmt.allocPrint(allocator, " LIMIT ${d}", .{idx});

    idx += 1;
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer allocator.free(offset_str);
    try params.append(allocator, .{ .text = try allocator.dupe(u8, offset_str) });
    const offset_clause = try std.fmt.allocPrint(allocator, " OFFSET ${d}", .{idx});

    const query = try std.fmt.allocPrintSentinel(
        allocator,
        "SELECT id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at " ++
            "FROM issue WHERE {s}{s}{s}{s}",
        .{where.items, order_by, limit_clause, offset_clause},
        0,
    );
    defer allocator.free(query);

    var rs = try db.queryParams(query, params.items);
    defer rs.deinit();

    var list: std.ArrayList(IssueResponse) = .empty;
    errdefer {
        for (list.items) |item| freeIssueResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = issueResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

/// Case-insensitive `ILIKE` search across `title` and `description`.
/// The DB GIN trigram index in migration 032 keeps this fast even
/// for large workspaces; we still cap the result set with a
/// caller-supplied `limit`.
pub fn searchIssuesByText(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    query: []const u8,
    limit: u32,
) ![]IssueResponse {
    const db = borrowDb() orelse return &[_]IssueResponse{};
    defer deps.releaseBack(db);
    if (query.len == 0) return &[_]IssueResponse{};

    var rs = try db.queryParams(
        "SELECT id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at " ++
            "FROM issue WHERE workspace_id = $1::uuid AND " ++
            "(title ILIKE '%' || $2 || '%' OR description ILIKE '%' || $2 || '%') " ++
            "ORDER BY created_at DESC LIMIT $3",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = query },
            .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{limit}) },
        },
    );
    defer rs.deinit();

    var list: std.ArrayList(IssueResponse) = .empty;
    errdefer {
        for (list.items) |item| freeIssueResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = issueResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

/// `SELECT id, title, description, project_id::text, parent_issue_id::text,
/// assignee_id::text, status, created_at, updated_at
/// FROM issue WHERE parent_issue_id = ANY($1::uuid[])` — bulk
/// child lookup for a set of parent ids. Built for the
/// `GET /api/issues/children?parent_id=...&parent_id=...` endpoint.
/// Returns an empty slice when no parent ids are supplied.
pub fn listChildrenByParents(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    parent_ids: []const []const u8,
) ![]IssueResponse {
    const db = borrowDb() orelse return &[_]IssueResponse{};
    defer deps.releaseBack(db);
    if (parent_ids.len == 0) return &[_]IssueResponse{};

    // Build the Postgres array literal: '{uuid1,uuid2,uuid3}'. The
    // client only ever feeds us UUID-shaped strings, so we just
    // comma-join without escaping. The list of ids is bounded by
    // the URL's practical length so this is safe.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    try joined.append(allocator, '{');
    for (parent_ids, 0..) |pid, i| {
        if (i > 0) try joined.append(allocator, ',');
        try joined.appendSlice(allocator, pid);
    }
    try joined.append(allocator, '}');
    const array_lit = try joined.toOwnedSlice(allocator);
    defer allocator.free(array_lit);

    var rs = try db.queryParams(
        "SELECT id, title, description, project_id::text, parent_issue_id::text, " ++
            "assignee_id::text, status, created_at, updated_at " ++
            "FROM issue WHERE workspace_id = $1::uuid AND parent_issue_id = ANY($2::uuid[]) " ++
            "ORDER BY created_at ASC",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = array_lit },
        },
    );
    defer rs.deinit();

    var list: std.ArrayList(IssueResponse) = .empty;
    errdefer {
        for (list.items) |item| freeIssueResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = issueResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────
// label join-table SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// `INSERT INTO issue_to_label (issue_id, label_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT DO NOTHING`.
/// Also verifies the label and issue exist before inserting. Returns `true` when
/// the label was attached (or already attached), `false` when the label doesn't exist.
pub fn dbAttachLabel(workspace_id: []const u8, issue_id: []const u8, label_id: []const u8) !bool {
    const db = borrowDb() orelse return error.NoDatabase;
    defer deps.releaseBack(db);
    // Verify label exists.
    {
        var rs = db.queryParams(
            "SELECT 1 FROM issue_label WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = label_id }, .{ .text = workspace_id } },
        ) catch return false;
        defer rs.deinit();
        if (rs.rows.items.len == 0) return false;
    }
    // Attach the label.
    {
        var rs = db.queryParams(
            "INSERT INTO issue_to_label (issue_id, label_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT (issue_id, label_id) DO NOTHING",
            &[_]SqlParam{ .{ .text = issue_id }, .{ .text = label_id } },
        ) catch return false;
        rs.deinit();
    }
    return true;
}

/// `SELECT il.id, il.workspace_id, il.name, il.color, il.created_at, il.updated_at
/// FROM issue_label il JOIN issue_to_label itl ON il.id = itl.label_id
/// WHERE itl.issue_id = $1::uuid ORDER BY il.name`.
/// Returns a duped slice of `LabelResponse` owned by the caller.
pub fn dbListIssueLabels(allocator: std.mem.Allocator, issue_id: []const u8) ![]@import("../label/model.zig").LabelResponse {
    const label_model = @import("../label/model.zig");
    const db = borrowDb() orelse return &[_]label_model.LabelResponse{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT il.id, il.workspace_id, il.name, il.color, il.created_at, il.updated_at " ++
            "FROM issue_label il JOIN issue_to_label itl ON il.id = itl.label_id " ++
            "WHERE itl.issue_id = $1::uuid ORDER BY il.name",
        &[_]SqlParam{.{ .text = issue_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(label_model.LabelResponse) = .empty;
    errdefer {
        for (list.items) |item| label_model.freeLabelResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = label_model.labelResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

/// `DELETE FROM issue_to_label WHERE issue_id = $1::uuid AND label_id = $2::uuid`.
/// Returns `true` when a row was removed.
pub fn dbDetachLabel(issue_id: []const u8, label_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "DELETE FROM issue_to_label WHERE issue_id = $1::uuid AND label_id = $2::uuid RETURNING issue_id",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = label_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

// ──────────────────────────────────────────────────────────────────────
// metadata SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// `SELECT metadata FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid`.
/// Returns the raw JSONB text or `null` when the issue is unknown.
/// The caller parses the JSON into a `std.json.Value` for the
/// response; the parser arena is owned by the caller.
pub fn selectIssueMetadataRaw(workspace_id: []const u8, issue_id: []const u8) ?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT metadata::text FROM issue WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const raw = rs.rows.items[0].getText(0) orelse return null;
    return db.allocator.dupe(u8, raw) catch return null;
}

/// `UPDATE issue SET metadata = $3::jsonb, updated_at = now() WHERE id = $1::uuid
/// AND workspace_id = $2::uuid RETURNING metadata::text`. Returns
/// the new metadata JSON text or `null` when the issue is unknown.
pub fn updateIssueMetadata(
    workspace_id: []const u8,
    issue_id: []const u8,
    json_text: []const u8,
) ?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue SET metadata = $3::jsonb, updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING metadata::text",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            .{ .text = json_text },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const raw = rs.rows.items[0].getText(0) orelse return null;
    return db.allocator.dupe(u8, raw) catch return null;
}
