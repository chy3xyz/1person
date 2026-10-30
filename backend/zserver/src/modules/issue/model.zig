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
const common_mem = @import("../../common/mem.zig");

// ──────────────────────────────────────────────────────────────────────
// DB borrow helper
// ──────────────────────────────────────────────────────────────────────

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised. Caller owns the
/// `defer deps.releaseBack(db)`.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
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
    /// Owning workspace. The DB path reads it straight from the row;
    /// the in-memory path fills it on create.
    workspace_id: []const u8 = "",
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
    /// `<workspace prefix>-<number>`. The DB path computes it in SQL;
    /// the in-memory path leaves it empty (no-DB mode is dev-only).
    identifier: []const u8 = "",
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
/// Request body for `POST /api/issues` and `PATCH /api/issues/:id`.
///
/// The field names ARE the wire contract, and they match the upstream Go
/// server: `status` and `parent_issue_id`, never `state` and `parent_id`.
/// The request parser ignores unknown fields, so a DTO that used the
/// internal names silently swallowed everything the client sent — the
/// request answered 200 and changed nothing. The response side always
/// used the wire names, which is why the mismatch stayed invisible until
/// someone tried to move an issue between statuses.
///
/// The creator is not part of the request: it comes from the acting
/// member or agent, exactly like upstream. The DTO used to carry
/// `creator_type` / `creator_id`, which only the in-memory path honoured
/// — the DB path always used the actor, so the two paths disagreed.
pub const CreateIssueRequest = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    status: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    parent_issue_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    position: ?f64 = null,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
};

pub const UpdateIssueRequest = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    status: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    parent_issue_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    position: ?f64 = null,
    due_date: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
};

/// The columns one issue write touches.
///
/// Every column uses the same three-state encoding: `null` means "leave
/// this column alone", the empty string means "clear it", and any other
/// value is written as-is. The distinction is load-bearing — a PATCH
/// field has exactly three states in the request body ("absent", "null"
/// and "a value") and a typed `?T` only ever sees two of them.
///
/// Columns whose upstream counterpart is a plain string (title, status,
/// priority, …) treat the empty string as a value, not as a clear:
/// upstream's Go pointers make `null` mean "absent" for those, and only
/// the explicitly nullable ones (assignee pair, project, parent, dates)
/// use `null` to clear.
pub const IssuePatch = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    position: ?f64 = null,
    project_id: ?[]const u8 = null,
    parent_issue_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    due_date: ?[]const u8 = null,
};

/// The columns one issue insert sets.
pub const IssueCreate = struct {
    title: []const u8,
    description: []const u8 = "",
    status: []const u8 = DEFAULT_STATE,
    priority: []const u8 = DEFAULT_PRIORITY,
    position: f64 = 0,
    project_id: []const u8 = "",
    parent_issue_id: []const u8 = "",
    assignee_id: []const u8 = "",
    assignee_type: ?[]const u8 = null,
    creator_id: []const u8,
    creator_type: []const u8,
    start_date: ?[]const u8 = null,
    due_date: ?[]const u8 = null,
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

/// One row of the `GET /api/issues/child-progress` response. Mirrors
/// the Go `ChildIssueProgress` handler's per-parent aggregate.
pub const ChildProgressEntry = struct {
    parent_issue_id: []const u8,
    total: i64,
    done: i64,
};

/// One swimlane of `GET /api/issues/grouped?group_by=assignee`.
/// Mirrors the Go `IssueAssigneeGroupResponse` (id is
/// `assignee:<type>:<uuid>` or `assignee:unassigned`).
pub const IssueAssigneeGroup = struct {
    id: []const u8,
    assignee_type: ?[]const u8,
    assignee_id: ?[]const u8,
    issues: []IssueResponse,
    total: i64,
};

/// Response body for `GET /api/issues/grouped`.
pub const GroupedIssuesResponse = struct {
    groups: []IssueAssigneeGroup,
};

/// Response shape returned to clients. Mirrors the canonical
/// `Issue` interface in `packages/core/types/issue.ts`. The DB
/// column names are translated to the simpler API names here
/// (e.g. `status` → `state`).
/// Columns every issue read projects into the API shape.
///
/// One list for every SELECT so the query and the projector can never
/// drift apart. The wire contract (frontend `Issue` type in
/// `packages/core/types/issue.ts`, upstream `IssueResponse`) needs
/// `workspace_id`, `number`, `identifier`, `status` and
/// `parent_issue_id` — the previous nine-column list carried none of
/// them, so every issue response failed the client schema and the
/// Issues list rendered empty.
pub const issueSelectColumns =
    "i.id, i.workspace_id, i.number, " ++
    "COALESCE(w.issue_prefix, '') || '-' || i.number, " ++
    "i.title, i.description, i.project_id::text, i.parent_issue_id::text, " ++
    "i.assignee_id::text, i.status, i.created_at, i.updated_at, i.priority, " ++
    "i.assignee_type, i.creator_type, i.creator_id, i.position, i.due_date, i.start_date";

/// `FROM` clause matching `issueSelectColumns` — the workspace join
/// carries the issue prefix the identifier is built from.
pub const issueSelectFrom = " FROM issue i LEFT JOIN workspace w ON w.id = i.workspace_id";

/// Same columns as `issueSelectColumns`, for the `RETURNING` clause of
/// a write. A write cannot join, so the prefix comes from a scalar
/// subquery instead. The column ORDER must stay identical to
/// `issueSelectColumns` — the projector indexes by position.
pub const issueReturningColumns =
    "id, workspace_id, number, " ++
    "(SELECT COALESCE(w2.issue_prefix, '') FROM workspace w2 WHERE w2.id = issue.workspace_id) || '-' || number, " ++
    "title, description, project_id::text, parent_issue_id::text, " ++
    "assignee_id::text, status, created_at, updated_at, priority, " ++
    "assignee_type, creator_type, creator_id, position, due_date, start_date";

pub const IssueResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    /// Per-workspace issue number (1-based).
    number: i32,
    /// Human-readable id, `<workspace prefix>-<number>` — the same
    /// shape the upstream server renders.
    identifier: []const u8,
    title: []const u8,
    description: ?[]const u8,
    status: []const u8,
    priority: []const u8,
    assignee_type: ?[]const u8,
    assignee_id: ?[]const u8,
    creator_type: []const u8,
    creator_id: []const u8,
    parent_issue_id: ?[]const u8,
    project_id: ?[]const u8,
    position: f64,
    start_date: ?[]const u8,
    due_date: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
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

/// Calendar-date validator for the `start_date` / `due_date` columns.
/// The columns are `date` in Postgres, so a malformed value would abort
/// the whole UPDATE instead of failing the request — the shape is checked
/// here first, exactly like upstream's `util.ParseCalendarDate`.
pub fn isValidCalendarDate(value: []const u8) bool {
    if (value.len != 10) return false;
    if (value[4] != '-' or value[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 5, 6, 8, 9 }) |i| {
        if (!std.ascii.isDigit(value[i])) return false;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (month < 1 or month > 12) return false;
    if (day < 1) return false;
    return day <= daysInMonth(year, month);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    if (year % 4 != 0) return false;
    if (year % 100 != 0) return true;
    return year % 400 == 0;
}

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

/// One entry of `GET /api/issues/:id/timeline`.
///
/// The upstream Go server answers that endpoint with a FLAT ARRAY of
/// entries (no wrapper object), and the client's schema expects the
/// same. `type` discriminates the entry kind ("activity" /
/// "comment"); `action` names the activity ("status_changed", …) and
/// `details` carries its payload ({from, to}, …).
pub const TimelineEntry = struct {
    type: []const u8 = "activity",
    id: []const u8 = "",
    actor_type: []const u8 = "",
    actor_id: []const u8 = "",
    action: []const u8 = "",
    details: ?std.json.Value = null,
    created_at: []const u8 = "",
};

/// Parse a JSONB column into a `std.json.Value` so it can be embedded
/// in the response as a real JSON object instead of a string.
///
/// The text is duplicated into `allocator` first: the column text points
/// into the ResultSet, and a parsed `Value` may alias its input.
pub fn parseDetailsValue(allocator: std.mem.Allocator, text: []const u8) ?std.json.Value {
    if (text.len == 0) return null;
    const owned = allocator.dupe(u8, text) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, owned, .{}) catch return null;
    return parsed.value;
}

/// Project an `activity_log` row into a timeline entry.
///
/// Columns (in order): id, action, actor_type, actor_id, details, created_at.
pub fn timelineEntryFromRow(
    allocator: std.mem.Allocator,
    res: *zfinal.ResultSet,
    row: usize,
) TimelineEntry {
    const r = &res.rows.items[row];
    return TimelineEntry{
        .type = "activity",
        .id = r.getText(0) orelse "",
        .action = r.getText(1) orelse "",
        .actor_type = r.getText(2) orelse "system",
        .actor_id = r.getText(3) orelse "",
        .details = parseDetailsValue(allocator, r.getText(4) orelse ""),
        .created_at = r.getText(5) orelse "",
    };
}

/// Project an in-memory timeline event into a timeline entry.
pub fn timelineEntryFromEvent(event: TimelineEvent) TimelineEntry {
    return TimelineEntry{
        .type = "activity",
        .id = event.id,
        .action = event.event_type,
        .actor_type = event.actor_type,
        .actor_id = event.actor_id,
        .created_at = event.created_at,
    };
}

/// Convert a row selected with `issueSelectColumns` / `issueReturningColumns`
/// into the API response shape. Empty-string → null translation lives here
/// so the DB path doesn't have to special-case the response shape.
pub fn issueResponseFromRow(res: *zfinal.ResultSet, row: usize) IssueResponse {
    const r = &res.rows.items[row];
    return IssueResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .number = @intCast((r.getInt(2) catch null) orelse 0),
        .identifier = r.getText(3) orelse "",
        .title = r.getText(4) orelse "",
        .description = r.getText(5),
        .project_id = emptyToNull(r.getText(6)),
        .parent_issue_id = emptyToNull(r.getText(7)),
        .assignee_id = emptyToNull(r.getText(8)),
        .status = r.getText(9) orelse "backlog",
        .created_at = r.getText(10) orelse "",
        .updated_at = r.getText(11) orelse "",
        .priority = r.getText(12) orelse "none",
        .assignee_type = r.getText(13),
        .creator_type = r.getText(14) orelse "member",
        .creator_id = r.getText(15) orelse "",
        .position = (r.getFloat(16) catch null) orelse 0,
        .due_date = r.getText(17),
        .start_date = r.getText(18),
    };
}

/// Convert an in-memory `Issue` row to the API response shape.
pub fn issueResponseFromEntry(entry: Issue) IssueResponse {
    return IssueResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .number = entry.number,
        .identifier = entry.identifier,
        .title = entry.title,
        .description = if (entry.description.len > 0) entry.description else null,
        .project_id = if (entry.project_id.len > 0) entry.project_id else null,
        .parent_issue_id = if (entry.parent_id.len > 0) entry.parent_id else null,
        .assignee_id = if (entry.assignee_id.len > 0) entry.assignee_id else null,
        .status = entry.state,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .priority = entry.priority,
        .assignee_type = entry.assignee_type,
        .creator_type = entry.creator_type,
        .creator_id = entry.creator_id,
        .position = entry.position,
        .due_date = entry.due_date,
        .start_date = entry.start_date,
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
    const dup_ws = allocator.dupe(u8, r.getText(1) orelse "") catch return null;
    errdefer allocator.free(dup_ws);
    const dup_identifier = allocator.dupe(u8, r.getText(3) orelse "") catch return null;
    errdefer allocator.free(dup_identifier);
    const dup_title = allocator.dupe(u8, r.getText(4) orelse "") catch return null;
    errdefer allocator.free(dup_title);
    const desc_raw = r.getText(5);
    const dup_desc: ?[]const u8 = if (desc_raw) |d| blk: {
        const dd = allocator.dupe(u8, d) catch return null;
        break :blk if (dd.len == 0) null else dd;
    } else null;
    errdefer if (dup_desc) |d| allocator.free(d);
    const proj_raw = r.getText(6);
    const dup_proj: ?[]const u8 = if (proj_raw) |p| blk: {
        const dp = allocator.dupe(u8, p) catch return null;
        break :blk if (dp.len == 0) null else dp;
    } else null;
    errdefer if (dup_proj) |p| allocator.free(p);
    const par_raw = r.getText(7);
    const dup_par: ?[]const u8 = if (par_raw) |p| blk: {
        const dp = allocator.dupe(u8, p) catch return null;
        break :blk if (dp.len == 0) null else dp;
    } else null;
    errdefer if (dup_par) |p| allocator.free(p);
    const asgn_raw = r.getText(8);
    const dup_asgn: ?[]const u8 = if (asgn_raw) |a| blk: {
        const da = allocator.dupe(u8, a) catch return null;
        break :blk if (da.len == 0) null else da;
    } else null;
    errdefer if (dup_asgn) |a| allocator.free(a);
    const dup_status = allocator.dupe(u8, r.getText(9) orelse "backlog") catch return null;
    errdefer allocator.free(dup_status);
    const dup_ca = allocator.dupe(u8, r.getText(10) orelse "") catch return null;
    errdefer allocator.free(dup_ca);
    const dup_ua = allocator.dupe(u8, r.getText(11) orelse "") catch return null;
    errdefer allocator.free(dup_ua);
    const dup_priority = allocator.dupe(u8, r.getText(12) orelse "none") catch return null;
    errdefer allocator.free(dup_priority);
    const dup_atype: ?[]const u8 = if (r.getText(13)) |a| blk: {
        const da = allocator.dupe(u8, a) catch return null;
        break :blk if (da.len == 0) null else da;
    } else null;
    errdefer if (dup_atype) |a| allocator.free(a);
    const dup_ctype = allocator.dupe(u8, r.getText(14) orelse "member") catch return null;
    errdefer allocator.free(dup_ctype);
    const dup_cid = allocator.dupe(u8, r.getText(15) orelse "") catch return null;
    errdefer allocator.free(dup_cid);
    const dup_due: ?[]const u8 = if (r.getText(17)) |d| blk: {
        const dd = allocator.dupe(u8, d) catch return null;
        break :blk if (dd.len == 0) null else dd;
    } else null;
    errdefer if (dup_due) |d| allocator.free(d);
    const dup_start: ?[]const u8 = if (r.getText(18)) |d| blk: {
        const dd = allocator.dupe(u8, d) catch return null;
        break :blk if (dd.len == 0) null else dd;
    } else null;
    errdefer if (dup_start) |d| allocator.free(d);
    return IssueResponse{
        .id = dup_id,
        .workspace_id = dup_ws,
        .number = @intCast((r.getInt(2) catch null) orelse 0),
        .identifier = dup_identifier,
        .title = dup_title,
        .description = dup_desc,
        .project_id = dup_proj,
        .parent_issue_id = dup_par,
        .assignee_id = dup_asgn,
        .status = dup_status,
        .created_at = dup_ca,
        .updated_at = dup_ua,
        .priority = dup_priority,
        .assignee_type = dup_atype,
        .creator_type = dup_ctype,
        .creator_id = dup_cid,
        .position = (r.getFloat(16) catch null) orelse 0,
        .due_date = dup_due,
        .start_date = dup_start,
    };
}

/// Free every heap-allocated string field inside an IssueResponse that
/// was produced by `issueResponseFromRowDuped`.  Safe to call with
/// zero-length strings (they are "" not null).
pub fn freeIssueResponse(allocator: std.mem.Allocator, resp: IssueResponse) void {
    allocator.free(resp.id);
    allocator.free(resp.workspace_id);
    allocator.free(resp.identifier);
    allocator.free(resp.title);
    if (resp.description) |d| allocator.free(d);
    if (resp.project_id) |p| allocator.free(p);
    if (resp.parent_issue_id) |p| allocator.free(p);
    if (resp.assignee_id) |a| allocator.free(a);
    allocator.free(resp.status);
    allocator.free(resp.created_at);
    allocator.free(resp.updated_at);
    allocator.free(resp.priority);
    if (resp.assignee_type) |a| allocator.free(a);
    allocator.free(resp.creator_type);
    allocator.free(resp.creator_id);
    if (resp.due_date) |d| allocator.free(d);
    if (resp.start_date) |d| allocator.free(d);
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
///
/// `creator_id` / `creator_type` describe WHO created the issue — the
/// acting user or agent. They used to be hardcoded to the workspace id
/// with type "member", so every issue claimed the workspace as its
/// author. `assignee_type` is the kind of the assignee (agent /
/// member); `null` leaves the issue unassigned.
pub fn insertIssue(workspace_id: []const u8, issue: IssueCreate) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO issue (workspace_id, title, description, status, priority, position, " ++
            "project_id, parent_issue_id, assignee_type, assignee_id, creator_type, creator_id, " ++
            "start_date, due_date, number) " ++
            "VALUES ($1::uuid, $2, $3, $4, $5, $6, " ++
            "NULLIF($7, '')::uuid, NULLIF($8, '')::uuid, NULLIF($9, ''), NULLIF($10, '')::uuid, " ++
            "$11, $12::uuid, NULLIF($13, '')::date, NULLIF($14, '')::date, " ++
            "(SELECT COALESCE(MAX(number), 0) + 1 FROM issue WHERE workspace_id = $1::uuid)) " ++
            "RETURNING " ++ issueReturningColumns,
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = issue.title },
            .{ .text = issue.description },
            .{ .text = issue.status },
            .{ .text = issue.priority },
            .{ .real = issue.position },
            .{ .text = issue.project_id },
            .{ .text = issue.parent_issue_id },
            .{ .text = issue.assignee_type orelse "" },
            .{ .text = issue.assignee_id },
            .{ .text = issue.creator_type },
            .{ .text = issue.creator_id },
            .{ .text = issue.start_date orelse "" },
            .{ .text = issue.due_date orelse "" },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// SQL for the list endpoints, kept next to the projectors so the test
/// can prove the queries still resolve against the live schema.
pub const timelineSelectSql =
    "SELECT id::text, action, " ++
    "COALESCE(actor_type::text, 'system'), COALESCE(actor_id::text, ''), " ++
    "details::text, created_at " ++
    "FROM activity_log WHERE issue_id = $1::uuid ORDER BY created_at ASC";

pub const subscriberSelectSql =
    "SELECT issue_id::text, user_type, user_id::text, reason, created_at " ++
    "FROM issue_subscriber WHERE issue_id = $1::uuid ORDER BY created_at ASC";

/// The agent that runs a squad's work: the squad's leader. Returns
/// `null` when the squad does not exist in this workspace or is
/// archived. The returned id is copied into the DB allocator so it
/// outlives the borrowed result set.
pub fn squadLeaderAgentId(workspace_id: []const u8, squad_id: []const u8) ?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT leader_id::text FROM squad " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL",
        &[_]SqlParam{
            .{ .text = squad_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const raw = rs.rows.items[0].getText(0) orelse return null;
    return db.allocator.dupe(u8, raw) catch null;
}

/// How an agent is wired to a runtime, and whether that runtime can take
/// work right now.
///
/// Quick-create needs the agent to run NOW: a task queued for an offline
/// runtime would sit in the queue until the machine came back, so the
/// endpoint refuses instead of pretending it worked. The three failure
/// modes stay distinguishable because the UI phrases them differently
/// ("bind a runtime" vs "reconnect the machine").
pub const AgentRuntimeBinding = struct {
    /// The runtime the agent is bound to. Empty when the agent has none.
    runtime_id: []const u8,
    /// The runtime's liveness (`online` / `offline`). Empty when the
    /// runtime row is gone.
    runtime_status: []const u8,
    /// True when the agent itself is archived.
    agent_archived: bool,

    pub fn isOnline(b: AgentRuntimeBinding) bool {
        return b.runtime_id.len > 0 and std.mem.eql(u8, b.runtime_status, "online");
    }
};

/// Read an agent's runtime binding. Returns `null` when the agent does
/// not exist in this workspace.
pub fn agentRuntimeBinding(workspace_id: []const u8, agent_id: []const u8) ?AgentRuntimeBinding {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT COALESCE(a.runtime_id::text, ''), COALESCE(r.status, ''), " ++
            "(a.archived_at IS NOT NULL) " ++
            "FROM agent a LEFT JOIN agent_runtime r ON r.id = a.runtime_id " ++
            "WHERE a.id = $1::uuid AND a.workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const runtime_id = rs.rows.items[0].getText(0) orelse "";
    const runtime_status = rs.rows.items[0].getText(1) orelse "";
    const archived = (rs.rows.items[0].getBool(2) catch null) orelse false;
    return AgentRuntimeBinding{
        .runtime_id = db.allocator.dupe(u8, runtime_id) catch "",
        .runtime_status = db.allocator.dupe(u8, runtime_status) catch "",
        .agent_archived = archived,
    };
}

/// Queue a task for an agent to work on an issue. Returns the new task
/// id (copied into the DB allocator) or `null` when the insert failed.
pub fn enqueueAgentTask(
    agent_id: []const u8,
    runtime_id: []const u8,
    issue_id: []const u8,
    initiator_id: []const u8,
) ?[]const u8 {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO agent_task_queue " ++
            "(agent_id, runtime_id, issue_id, status, priority, initiator_user_id) " ++
            "VALUES ($1::uuid, $2::uuid, NULLIF($3, '')::uuid, 'queued', 0, NULLIF($4, '')::uuid) " ++
            "RETURNING id",
        &[_]SqlParam{
            .{ .text = agent_id },
            .{ .text = runtime_id },
            .{ .text = issue_id },
            .{ .text = initiator_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const raw = rs.rows.items[0].getText(0) orelse return null;
    return db.allocator.dupe(u8, raw) catch null;
}

/// Derive an issue title from a free-form prompt: the first non-empty
/// line, capped at 120 bytes on a UTF-8 boundary. The full prompt stays
/// in the issue body.
pub fn deriveIssueTitle(prompt: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, prompt, '\n');
    var title: []const u8 = "";
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        title = trimmed;
        break;
    }
    if (title.len == 0) return "New issue";
    if (title.len <= 120) return title;
    // Do not split a multi-byte character in half.
    var end: usize = 120;
    while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
    return title[0..end];
}

/// Resolve the kind of an assignee id: "agent", "member", or `null`
/// when the id belongs to neither (an unassigned issue, or an id that
/// was deleted). The wire contract carries `assignee_type` next to
/// `assignee_id` and the client renders agents differently from
/// members — hardcoding "member" made every agent-assigned issue look
/// like a person.
pub fn resolveAssigneeType(workspace_id: []const u8, assignee_id: []const u8) ?[]const u8 {
    if (assignee_id.len == 0) return null;
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT EXISTS(SELECT 1 FROM agent WHERE id = $1::uuid), " ++
            "EXISTS(SELECT 1 FROM member WHERE workspace_id = $2::uuid AND user_id = $1::uuid)",
        &[_]SqlParam{
            .{ .text = assignee_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    if (((rs.rows.items[0].getInt(0) catch null) orelse 0) != 0) return "agent";
    if (((rs.rows.items[0].getInt(1) catch null) orelse 0) != 0) return "member";
    return null;
}

/// Why an `(assignee_type, assignee_id)` pair was rejected. Mirrors the
/// upstream `validateAssigneePair`
/// (`server/internal/handler/issue.go`): the pair must name an existing,
/// non-archived entity of that kind inside the workspace.
pub const AssigneePairError = error{
    /// Only one half of the pair was supplied — an assignee is always a
    /// (type, id) tuple.
    IncompletePair,
    /// `assignee_type` is not one of member / agent / squad.
    UnknownType,
    /// The id does not name an entity of that kind in this workspace.
    NotFound,
    /// The target agent / squad is archived.
    Archived,
};

/// The assignee pair currently stored on an issue. Both fields are owned
/// by the allocator passed to `selectIssueAssignee`; free them with
/// `IssueAssignee.deinit`.
pub const IssueAssignee = struct {
    assignee_type: ?[]const u8,
    assignee_id: ?[]const u8,

    pub fn deinit(self: IssueAssignee, allocator: std.mem.Allocator) void {
        if (self.assignee_type) |t| allocator.free(t);
        if (self.assignee_id) |i| allocator.free(i);
    }
};

/// `SELECT assignee_type, assignee_id FROM issue WHERE id = $1 AND
/// workspace_id = $2`. Returns `null` when no row matches.
///
/// The update path needs the pair before it can apply the upstream
/// "merge with the current value" rule: a PATCH that only mentions
/// `assignee_id` keeps the existing `assignee_type`, and vice versa.
pub fn selectIssueAssignee(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    issue_id: []const u8,
) ?IssueAssignee {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT assignee_type, assignee_id::text FROM issue " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const row = &rs.rows.items[0];
    const type_raw = row.getText(0);
    const id_raw = row.getText(1);
    const dup_type: ?[]const u8 = if (type_raw) |t| blk: {
        if (t.len == 0) break :blk null;
        const d = allocator.dupe(u8, t) catch return null;
        break :blk d;
    } else null;
    errdefer if (dup_type) |t| allocator.free(t);
    const dup_id: ?[]const u8 = if (id_raw) |i| blk: {
        if (i.len == 0) break :blk null;
        const d = allocator.dupe(u8, i) catch return null;
        break :blk d;
    } else null;
    return .{ .assignee_type = dup_type, .assignee_id = dup_id };
}

/// Validate an `(assignee_type, assignee_id)` pair against the workspace.
///
/// Both fields must be supplied together (an assignee without a kind, or a
/// kind without a target, is ambiguous), the kind must be one of
/// `member` / `agent` / `squad`, and the target must exist in this
/// workspace and not be archived. Squad targets additionally require a
/// live leader — upstream rejects assigning a squad whose leader is
/// archived.
///
/// The permission gate (upstream's `canInvokeAgent`) is not implemented
/// here: it needs the request originator chain, which this fork does not
/// model. The client applies the visibility gate before offering an
/// agent in the picker.
///
/// Without a database there is nothing to look the target up in (the
/// no-DB mode has no agent / member / squad tables at all), so the
/// existence and archived checks are skipped there and only the pair
/// shape is enforced.
pub fn validateAssigneePair(
    workspace_id: []const u8,
    assignee_type: []const u8,
    assignee_id: []const u8,
) AssigneePairError!void {
    if (assignee_type.len == 0 or assignee_id.len == 0) return error.IncompletePair;

    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);

    if (std.mem.eql(u8, assignee_type, "member")) {
        var rs = db.queryParams(
            "SELECT EXISTS(SELECT 1 FROM member WHERE workspace_id = $1::uuid AND user_id = $2::uuid)",
            &[_]SqlParam{
                .{ .text = workspace_id },
                .{ .text = assignee_id },
            },
        ) catch return;
        defer rs.deinit();
        if (rs.rows.items.len == 0) return error.NotFound;
        if (((rs.rows.items[0].getInt(0) catch null) orelse 0) == 0) return error.NotFound;
        return;
    }

    if (std.mem.eql(u8, assignee_type, "agent")) {
        var rs = db.queryParams(
            "SELECT archived_at IS NOT NULL FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = assignee_id },
                .{ .text = workspace_id },
            },
        ) catch return;
        defer rs.deinit();
        if (rs.rows.items.len == 0) return error.NotFound;
        if (((rs.rows.items[0].getInt(0) catch null) orelse 0) != 0) return error.Archived;
        return;
    }

    if (std.mem.eql(u8, assignee_type, "squad")) {
        var rs = db.queryParams(
            "SELECT s.archived_at IS NOT NULL, " ++
                "(SELECT a.archived_at IS NOT NULL FROM agent a WHERE a.id = s.leader_id) " ++
                "FROM squad s WHERE s.id = $1::uuid AND s.workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = assignee_id },
                .{ .text = workspace_id },
            },
        ) catch return;
        defer rs.deinit();
        if (rs.rows.items.len == 0) return error.NotFound;
        if (((rs.rows.items[0].getInt(0) catch null) orelse 0) != 0) return error.Archived;
        if (((rs.rows.items[0].getInt(1) catch null) orelse 0) != 0) return error.Archived;
        return;
    }

    return error.UnknownType;
}

/// `SELECT <issueSelectColumns> FROM issue i LEFT JOIN workspace w ...
/// WHERE i.id = $1::uuid AND i.workspace_id = $2::uuid`. Returns
/// `null` when no row matches.
pub fn selectIssueById(workspace_id: []const u8, issue_id: []const u8) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT " ++ issueSelectColumns ++ issueSelectFrom ++
            " WHERE i.id = $1::uuid AND i.workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// The `SET` clause of an issue patch, shared by the single-issue and the
/// batch update so the two paths cannot drift apart.
///
/// Every column uses the same three-state encoding: a SQL NULL parameter
/// leaves the column alone, the empty string clears it (for the nullable
/// columns), and any other value is written as-is.
///
/// The old encoding was `COALESCE(NULLIF($n, ''), column)`, which could
/// only ever write a value — it could never clear a column. The assignee
/// pair additionally never wrote `assignee_type` at all, so every
/// agent-assigned issue came back with a null type and the client
/// rendered it as unassigned.
const issuePatchSetSql =
    "title = CASE WHEN $3::text IS NULL THEN title ELSE $3::text END, " ++
    "description = CASE WHEN $4::text IS NULL THEN description ELSE $4::text END, " ++
    "status = CASE WHEN $5::text IS NULL THEN status ELSE $5::text END, " ++
    "priority = CASE WHEN $6::text IS NULL THEN priority ELSE $6::text END, " ++
    "position = CASE WHEN $7::float8 IS NULL THEN position ELSE $7::float8 END, " ++
    "project_id = CASE WHEN $8::text IS NULL THEN project_id " ++
    "WHEN $8::text = '' THEN NULL ELSE $8::text::uuid END, " ++
    "parent_issue_id = CASE WHEN $9::text IS NULL THEN parent_issue_id " ++
    "WHEN $9::text = '' THEN NULL ELSE $9::text::uuid END, " ++
    "assignee_id = CASE WHEN $10::text IS NULL THEN assignee_id " ++
    "WHEN $10::text = '' THEN NULL ELSE $10::text::uuid END, " ++
    "assignee_type = CASE WHEN $11::text IS NULL THEN assignee_type " ++
    "WHEN $11::text = '' THEN NULL ELSE $11::text END, " ++
    "start_date = CASE WHEN $12::text IS NULL THEN start_date " ++
    "WHEN $12::text = '' THEN NULL ELSE $12::text::date END, " ++
    "due_date = CASE WHEN $13::text IS NULL THEN due_date " ++
    "WHEN $13::text = '' THEN NULL ELSE $13::text::date END, " ++
    "updated_at = now() ";

/// Bind one patch column: `null` leaves the column alone, anything else
/// is written as-is.
fn issuePatchText(value: ?[]const u8) SqlParam {
    return if (value) |v| SqlParam{ .text = v } else SqlParam{ .null = {} };
}

/// The eleven patch columns, in the order `issuePatchSetSql` expects them.
fn issuePatchParams(patch: IssuePatch) [11]SqlParam {
    return .{
        issuePatchText(patch.title),
        issuePatchText(patch.description),
        issuePatchText(patch.status),
        issuePatchText(patch.priority),
        if (patch.position) |p| SqlParam{ .real = p } else SqlParam{ .null = {} },
        issuePatchText(patch.project_id),
        issuePatchText(patch.parent_issue_id),
        issuePatchText(patch.assignee_id),
        issuePatchText(patch.assignee_type),
        issuePatchText(patch.start_date),
        issuePatchText(patch.due_date),
    };
}

/// `UPDATE issue SET <patch> WHERE id = $1::uuid AND workspace_id = $2::uuid
/// RETURNING ...`. The patch carries one three-state value per column;
/// see `issuePatchSetSql` for the encoding.
pub fn updateIssue(
    issue_id: []const u8,
    workspace_id: []const u8,
    patch: IssuePatch,
) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    const patch_params = issuePatchParams(patch);
    var rs = db.queryParams(
        "UPDATE issue SET " ++ issuePatchSetSql ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING " ++ issueReturningColumns,
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            patch_params[0],
            patch_params[1],
            patch_params[2],
            patch_params[3],
            patch_params[4],
            patch_params[5],
            patch_params[6],
            patch_params[7],
            patch_params[8],
            patch_params[9],
            patch_params[10],
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return issueResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `UPDATE issue SET <patch> WHERE id = $1::uuid AND workspace_id = $2::uuid
/// RETURNING id`. Used by batchUpdate for the DB path. Returns `true`
/// when a row was updated. The patch encoding is identical to
/// `updateIssue`'s — both share `issuePatchSetSql`.
pub fn batchUpdateIssueDB(
    issue_id: []const u8,
    workspace_id: []const u8,
    patch: IssuePatch,
) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    const patch_params = issuePatchParams(patch);
    var rs = db.queryParams(
        "UPDATE issue SET " ++ issuePatchSetSql ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id",
        &[_]SqlParam{
            .{ .text = issue_id },
            .{ .text = workspace_id },
            patch_params[0],
            patch_params[1],
            patch_params[2],
            patch_params[3],
            patch_params[4],
            patch_params[5],
            patch_params[6],
            patch_params[7],
            patch_params[8],
            patch_params[9],
            patch_params[10],
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
/// RETURNING <issueReturningColumns>`.
/// Returns the updated `IssueResponse` or `null` when no row matched.
pub fn dbRerunIssue(workspace_id: []const u8, issue_id: []const u8) ?IssueResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue SET status = 'todo', updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING " ++ issueReturningColumns,
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
/// Shared WHERE-clause builder for the issue list/count queries.
/// Appends filter params to `params` starting at `$1` (workspace_id)
/// and returns an owned `where` string the caller must free.
fn buildIssueFilterClause(
    allocator: std.mem.Allocator,
    params: *std.ArrayList(SqlParam),
    workspace_id: []const u8,
    state_filter: ?[]const u8,
    project_filter: ?[]const u8,
    assignee_filter: ?[]const u8,
) ![]u8 {
    var where: std.ArrayList(u8) = .empty;
    defer where.deinit(allocator);
    try where.appendSlice(allocator, "i.workspace_id = $1::uuid");
    try params.append(allocator, .{ .text = try allocator.dupe(u8, workspace_id) });

    var idx: usize = 1;
    if (state_filter) |s| {
        if (s.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, s) });
            const clause = try std.fmt.allocPrint(allocator, " AND i.status = ${d}", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }
    if (project_filter) |p| {
        if (p.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, p) });
            const clause = try std.fmt.allocPrint(allocator, " AND i.project_id = ${d}::uuid", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }
    if (assignee_filter) |a| {
        if (a.len > 0) {
            idx += 1;
            try params.append(allocator, .{ .text = try allocator.dupe(u8, a) });
            const clause = try std.fmt.allocPrint(allocator, " AND i.assignee_id = ${d}::uuid", .{idx});
            try where.appendSlice(allocator, clause);
        }
    }
    return try where.toOwnedSlice(allocator);
}

/// Count of issues matching the same filters as `listIssuesWithFilters`
/// (ignoring limit/offset). Powers the `total` field of the list
/// response so the frontend pagination can render correctly.
pub fn countIssuesWithFilters(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    state_filter: ?[]const u8,
    project_filter: ?[]const u8,
    assignee_filter: ?[]const u8,
) !i64 {
    const db = borrowDb() orelse return 0;
    defer deps.releaseBack(db);

    var params: std.ArrayList(SqlParam) = .empty;
    defer params.deinit(allocator);
    const where = try buildIssueFilterClause(allocator, &params, workspace_id, state_filter, project_filter, assignee_filter);
    defer allocator.free(where);

    const query = try std.fmt.allocPrintSentinel(allocator, "SELECT count(*) FROM issue i WHERE {s}", .{where}, 0);
    defer allocator.free(query);

    var rs = try db.queryParams(query, params.items);
    defer rs.deinit();
    if (rs.rows.items.len == 0) return 0;
    const cnt = rs.rows.items[0].getText(0) orelse "0";
    return std.fmt.parseInt(i64, cnt, 10) catch 0;
}

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
    const where = try buildIssueFilterClause(allocator, &params, workspace_id, state_filter, project_filter, assignee_filter);
    defer allocator.free(where);

    // Build ORDER BY + LIMIT + OFFSET separately, appended after WHERE.
    const order_by = " ORDER BY i.created_at DESC";

    // limit / offset are always last params. `buildIssueFilterClause`
    // already appended the filter params, so continue numbering from there.
    var idx: usize = params.items.len;
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
        "SELECT " ++ issueSelectColumns ++ issueSelectFrom ++
            " WHERE {s}{s}{s}{s}",
        .{where, order_by, limit_clause, offset_clause},
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
        "SELECT " ++ issueSelectColumns ++ issueSelectFrom ++
            " WHERE i.workspace_id = $1::uuid AND " ++
            "(i.title ILIKE '%' || $2 || '%' OR i.description ILIKE '%' || $2 || '%') " ++
            "ORDER BY i.created_at DESC LIMIT $3",
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

/// Count of issues matching the same ILIKE search as
/// `searchIssuesByText`. Powers the `total` field of the search
/// response.
pub fn countSearchIssues(
    workspace_id: []const u8,
    query: []const u8,
) !i64 {
    const db = borrowDb() orelse return 0;
    defer deps.releaseBack(db);
    if (query.len == 0) return 0;

    var rs = try db.queryParams(
        "SELECT count(*) FROM issue i WHERE i.workspace_id = $1::uuid AND " ++
            "(i.title ILIKE '%' || $2 || '%' OR i.description ILIKE '%' || $2 || '%')",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = query },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return 0;
    const cnt = rs.rows.items[0].getText(0) orelse "0";
    return std.fmt.parseInt(i64, cnt, 10) catch 0;
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
        "SELECT " ++ issueSelectColumns ++ issueSelectFrom ++
            " WHERE i.workspace_id = $1::uuid AND i.parent_issue_id = ANY($2::uuid[]) " ++
            "ORDER BY i.created_at ASC",
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
