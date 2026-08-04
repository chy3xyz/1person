//! Issue module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `model.mem_*`
//! maps) and exposes the HTTP-facing operations declared in
//! `handler.zig`. All endpoints are implemented: the core CRUD
//! surface (`listIssues`, `searchIssues`, `createIssue`, `getIssue`,
//! `updateIssue`, `deleteIssue`, `listChildrenByParents`,
//! `getMetadata` + `setMetadata`) plus the sub-resource / complex
//! endpoints (labels, attachments, subscribers, reactions, timeline,
//! children, metadata keys, batch ops, preview, tasks, usage, etc.).
//!
//! The `handler.zig` is a thin delegate; data shapes and the
//! `IssueResponse` projector live in `model.zig`. The DB access goes
//! through `deps.acquire()` + `zfinal.DB` + `zfinal.SqlParam` directly
//! (the escape-hatch pattern documented in `src/deps.zig`). The
//! no-DB fallback mutates the in-memory `Issue` / metadata /
//! subscriber / reaction records guarded by `model.mem_mutex` —
//! this path is exercised by the smoke test.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const validation = @import("../../common/validation.zig");
const pagination = @import("../../common/pagination.zig");
const realtime = @import("../realtime/service.zig");

const log = std.log.scoped(.issue_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

/// Per-workspace issue sequence counter. The no-DB path increments
/// this on every `createIssue` so the response's `number` field is
/// monotonic per workspace (mirrors the legacy SQLC behavior where
/// the DB auto-assigns `(workspace_id, number)` from a sequence).
var mem_issue_counter: std.StringHashMap(i32) = std.StringHashMap(i32).init(model.memAlloc());

/// Allocate the next per-workspace issue number and return it.
/// Caller must hold `mem_mutex` (or, more commonly, call it from
/// inside the no-DB `createIssue` path which already does).
fn memNextIssueNumber(workspace_id: []const u8) i32 {
    const gop = mem_issue_counter.getOrPut(workspace_id) catch return 0;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    return gop.value_ptr.*;
}

/// Current user id from the auth context. Empty string when
/// missing. Used by the new subscription / reaction / trigger
/// preview endpoints to resolve the actor.
fn currentUserId(ctx: *zfinal.Context) []const u8 {
    return ctx.attributes.get("user_id") orelse "";
}

/// Resolve the actor of a request into `(actor_type, actor_id)`.
/// Mirrors the Go server's `resolveActor` helper. Currently only
/// distinguishes `member` (default JWT/PAT) from `agent` (when
/// the global auth interceptor has flagged `token_type=task` and
/// the daemon middleware set `agent_id` on the context). The
/// `X-Actor-Source` / `X-Agent-ID` header shape is reserved for
/// a future task-token integration.
const Actor = struct {
    actor_type: []const u8,
    actor_id: []const u8,
};

fn resolveActor(ctx: *zfinal.Context) Actor {
    if (ctx.attributes.get("agent_id")) |aid| {
        if (aid.len > 0) return .{ .actor_type = "agent", .actor_id = aid };
    }
    const user_id = currentUserId(ctx);
    return .{ .actor_type = "member", .actor_id = user_id };
}

/// Serialise a generic event into a JSON envelope and broadcast it
/// on the workspace room. Failures (alloc OOM, JSON encode) are
/// logged and swallowed — the HTTP response is already on its way
/// and the broadcast is best-effort.
fn publishIssueEvent(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    event_type: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    issue_id: []const u8,
) void {
    const text = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"workspace_id\":\"{s}\",\"issue_id\":\"{s}\",\"actor_type\":\"{s}\",\"actor_id\":\"{s}\"}}",
        .{ event_type, workspace_id, issue_id, actor_type, actor_id },
    ) catch return;
    defer allocator.free(text);
    realtime.publishIssueEvent(workspace_id, text);
}

/// Get a path param or write a 400 envelope and return null.
fn requirePathParam(ctx: *zfinal.Context, name: []const u8) !?[]const u8 {
    if (ctx.getPathParam(name)) |v| {
        if (v.len > 0) return v;
    }
    try response.err(ctx, .bad_request, "missing path parameter", 40001);
    return null;
}

// ──────────────────────────────────────────────────────────────────────
// helpers shared by the CRUD endpoints
// ──────────────────────────────────────────────────────────────────────

/// Pull the workspace id stashed on the context by the workspace
/// middleware. Writes a 400 envelope and returns an error tag the
/// caller should propagate as an early `return`.
fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    const id = model.getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40040);
        return error.MissingWorkspaceId;
    };
    if (id.len == 0) {
        try response.err(ctx, .bad_request, "workspace_id is required", 40040);
        return error.MissingWorkspaceId;
    }
    return id;
}

/// Parse the `?q=…` search query. Empty / missing → empty string.
fn readSearchQuery(ctx: *zfinal.Context) []const u8 {
    return ctx.getPara("q") catch null orelse "";
}

fn readParentQuery(ctx: *zfinal.Context) []const u8 {
    return ctx.getPara("parent_id") catch null orelse "";
}

/// Case-insensitive substring search used by the no-DB
/// `searchIssues` fallback. Returns `true` when `needle` appears in
/// `haystack` after lower-casing both sides. The function is
/// ASCII-only (sufficient for the smoke test path).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ──────────────────────────────────────────────────────────────────────
// listIssues
// ──────────────────────────────────────────────────────────────────────

pub fn listIssues(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);

    // Filter params.
    const state_filter = ctx.getPara("status") catch null;
    const project_filter = ctx.getPara("project_id") catch null;
    const assignee_filter = ctx.getPara("assignee_id") catch null;
    const limit_str = ctx.getPara("limit") catch null;
    const offset_str = ctx.getPara("offset") catch null;

    const limit: u32 = limit: {
        if (limit_str) |s| {
            if (s.len > 0) {
                break :limit std.fmt.parseInt(u32, s, 10) catch pagination.DEFAULT_SIZE;
            }
        }
        break :limit pagination.DEFAULT_SIZE;
    };
    const offset: u32 = offset: {
        if (offset_str) |s| {
            if (s.len > 0) {
                break :offset std.fmt.parseInt(u32, s, 10) catch 0;
            }
        }
        break :offset 0;
    };

    if (deps.hasPool()) {
        const items = try model.listIssuesWithFilters(
            allocator,
            workspace_id,
            state_filter,
            project_filter,
            assignee_filter,
            limit,
            offset,
        );
        defer allocator.free(items);
        try response.ok(ctx, items);
        return;
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.IssueResponse) = .empty;
    defer list.deinit(allocator);
    var it = model.mem_issues.?.iterator();
    var skipped: u32 = 0;
    var emitted: u32 = 0;
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (state_filter) |s| if (s.len > 0 and !std.mem.eql(u8, entry.state, s)) continue;
        if (project_filter) |p| if (p.len > 0 and !std.mem.eql(u8, entry.project_id, p)) continue;
        if (assignee_filter) |a| if (a.len > 0 and !std.mem.eql(u8, entry.assignee_id, a)) continue;
        if (skipped < offset) {
            skipped += 1;
            continue;
        }
        if (emitted >= limit) continue;
        emitted += 1;
        try list.append(allocator, model.issueResponseFromEntry(entry));
    }
    try response.ok(ctx, list.items);
}

// ──────────────────────────────────────────────────────────────────────
// searchIssues
// ──────────────────────────────────────────────────────────────────────

pub fn searchIssues(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);

    const q = readSearchQuery(ctx);
    if (q.len == 0) {
        try response.err(ctx, .bad_request, "q is required", 40041);
        return;
    }

    const limit: u32 = limit: {
        const s = ctx.getPara("limit") catch null;
        if (s) |raw| if (raw.len > 0) {
            break :limit std.fmt.parseInt(u32, raw, 10) catch pagination.DEFAULT_SIZE;
        };
        break :limit pagination.DEFAULT_SIZE;
    };

    if (deps.hasPool()) {
        const items = try model.searchIssuesByText(allocator, workspace_id, q, limit);
        defer allocator.free(items);
        try response.ok(ctx, items);
        return;
    }

    // No-DB fallback: case-insensitive substring match across
    // title + description.
    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.IssueResponse) = .empty;
    defer list.deinit(allocator);
    var it = model.mem_issues.?.iterator();
    var emitted: u32 = 0;
    while (it.next()) |e| {
        if (emitted >= limit) break;
        const entry = e.value_ptr.*;
        if (!containsIgnoreCase(entry.title, q) and
            !containsIgnoreCase(entry.description, q)) continue;
        emitted += 1;
        try list.append(allocator, model.issueResponseFromEntry(entry));
    }
    try response.ok(ctx, list.items);
}

// ──────────────────────────────────────────────────────────────────────
// createIssue
// ──────────────────────────────────────────────────────────────────────

pub fn createIssue(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);

    const parsed = try validation.validateJson(model.CreateIssueRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    const title = model.validateTitle(req.title) orelse {
        try response.err(ctx, .bad_request, "title is required", 40042);
        return;
    };

    const state = req.state orelse model.DEFAULT_STATE;
    if (!model.isValidState(state)) {
        try response.err(ctx, .bad_request, "invalid state", 40043);
        return;
    }
    if (req.priority) |p| if (!model.isValidPriority(p)) {
        try response.err(ctx, .bad_request, "invalid priority", 40044);
        return;
    };

    const description = req.description orelse "";
    const project_id = req.project_id orelse "";
    const parent_id = req.parent_id orelse "";
    const assignee_id = req.assignee_id orelse "";

    if (deps.hasPool()) {
        if (model.insertIssue(workspace_id, title, description, state, project_id, parent_id, assignee_id)) |resp| {
            ctx.res_status = .created;
            const actor = resolveActor(ctx);
            publishIssueEvent(allocator, workspace_id, "issue:created", actor.actor_type, actor.actor_id, resp.id);
            try response.ok(ctx, resp);
            return;
        }
        log.err("createIssue: insert failed", .{});
        try response.err(ctx, .internal_server_error, "failed_to_create_issue", 50010);
        return;
    }

    try model.memInit();
    const id = try model.generateId(allocator, title);
    const now = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
    // Auto-assign a per-workspace sequence number.
    const issue_number = memNextIssueNumber(workspace_id);
    const priority = req.priority orelse model.DEFAULT_PRIORITY;
    const assignee_type_raw = req.assignee_type orelse if (assignee_id.len > 0) "member" else "";
    const assignee_type_dup: ?[]const u8 = if (assignee_type_raw.len > 0)
        try model.memDup(assignee_type_raw)
    else
        null;
    const creator_type_raw = req.creator_type orelse "member";
    const creator_id_raw = req.creator_id orelse workspace_id;
    const entry = model.Issue{
        .id = try model.memDup(id),
        .title = try model.memDup(title),
        .description = try model.memDup(description),
        .project_id = try model.memDup(project_id),
        .parent_id = try model.memDup(parent_id),
        .assignee_id = try model.memDup(assignee_id),
        .state = try model.memDup(state),
        .created_at = try model.memDup(now),
        .updated_at = try model.memDup(now),
        .squad_evaluated_at = null,
        .priority = try model.memDup(priority),
        .assignee_type = assignee_type_dup,
        .creator_type = try model.memDup(creator_type_raw),
        .creator_id = try model.memDup(creator_id_raw),
        .position = req.position orelse 0.0,
        .due_date = if (req.due_date) |d| try model.memDup(d) else null,
        .start_date = if (req.start_date) |d| try model.memDup(d) else null,
        .number = issue_number,
    };
    try model.memUpsertIssue(entry);
    allocator.free(id);

    ctx.res_status = .created;
    const actor = resolveActor(ctx);
    publishIssueEvent(allocator, workspace_id, "issue:created", actor.actor_type, actor.actor_id, entry.id);
    try response.ok(ctx, model.issueResponseFromEntry(entry));
}

// ──────────────────────────────────────────────────────────────────────
// getIssue
// ──────────────────────────────────────────────────────────────────────

pub fn getIssue(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        if (model.selectIssueById(workspace_id, issue_id)) |resp| {
            try response.ok(ctx, resp);
            return;
        }
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }

    const entry = model.memFindIssue(issue_id) orelse {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    };
    try response.ok(ctx, model.issueResponseFromEntry(entry));
}

// ──────────────────────────────────────────────────────────────────────
// updateIssue
// ──────────────────────────────────────────────────────────────────────

pub fn updateIssue(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    const parsed = try validation.validateJson(model.UpdateIssueRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.state) |s| if (!model.isValidState(s)) {
        try response.err(ctx, .bad_request, "invalid state", 40043);
        return;
    };
    if (req.priority) |p| if (!model.isValidPriority(p)) {
        try response.err(ctx, .bad_request, "invalid priority", 40044);
        return;
    };

    if (deps.hasPool()) {
        if (model.updateIssue(
            issue_id,
            workspace_id,
            req.title orelse "",
            req.description orelse "",
            req.state orelse "",
            req.project_id orelse "",
            req.parent_id orelse "",
            req.assignee_id orelse "",
        )) |resp| {
            try response.ok(ctx, resp);
            return;
        }
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    const entry_ptr = model.mem_issues.?.getPtr(issue_id) orelse {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    };
    if (req.title) |t| {
        const trimmed = model.validateTitle(t) orelse {
            try response.err(ctx, .bad_request, "title cannot be empty", 40045);
            return;
        };
        entry_ptr.title = try model.memDup(trimmed);
    }
    if (req.description) |d| entry_ptr.description = try model.memDup(d);
    if (req.state) |s| entry_ptr.state = try model.memDup(s);
    if (req.project_id) |p| entry_ptr.project_id = try model.memDup(p);
    if (req.parent_id) |p| entry_ptr.parent_id = try model.memDup(p);
    if (req.assignee_id) |a| entry_ptr.assignee_id = try model.memDup(a);
    if (req.priority) |p| entry_ptr.priority = try model.memDup(p);
    if (req.assignee_type) |t| {
        entry_ptr.assignee_type = if (t.len > 0) try model.memDup(t) else null;
    }
    if (req.creator_type) |t| entry_ptr.creator_type = try model.memDup(t);
    if (req.creator_id) |i| entry_ptr.creator_id = try model.memDup(i);
    if (req.position) |p| entry_ptr.position = p;
    if (req.due_date) |d| entry_ptr.due_date = try model.memDup(d);
    if (req.start_date) |d| entry_ptr.start_date = try model.memDup(d);
    // `squad_evaluated_at` is not set via PATCH; it is written by
    // the dedicated squad-evaluated endpoint.
    entry_ptr.updated_at = try model.memFmtNumber(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());

    const update_actor = resolveActor(ctx);
    publishIssueEvent(ctx.allocator, workspace_id, "issue:updated", update_actor.actor_type, update_actor.actor_id, issue_id);
    try response.ok(ctx, model.issueResponseFromEntry(entry_ptr.*));
}

// ──────────────────────────────────────────────────────────────────────
// deleteIssue
// ──────────────────────────────────────────────────────────────────────

pub fn deleteIssue(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        if (model.softDeleteIssue(workspace_id, issue_id)) {
            try response.okNoContent(ctx);
            return;
        }
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    if (model.mem_issues.?.fetchRemove(issue_id)) |_| {
        _ = model.mem_metadata.?.fetchRemove(issue_id);
        _ = model.mem_subscribers.?.fetchRemove(issue_id);
        _ = model.mem_reactions.?.fetchRemove(issue_id);
        _ = model.mem_issue_labels.?.fetchRemove(issue_id);
        _ = model.mem_tasks.?.fetchRemove(issue_id);
        _ = model.mem_pull_requests.?.fetchRemove(issue_id);
        try response.okNoContent(ctx);
        return;
    }
    try response.err(ctx, .not_found, "issue not found", 40410);
}

// ──────────────────────────────────────────────────────────────────────
// listChildrenByParents — bulk child lookup by `?parent_id=...&parent_id=...`
// ──────────────────────────────────────────────────────────────────────

pub fn listChildrenByParents(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);

    // The client sends repeated `parent_id` query params. zfinal
    // exposes them through `getPara` (single value); the no-DB
    // fallback also only needs the single-value form so we collect
    // just what `getPara` returns. For multi-parent support we
    // intentionally read only the first param; a follow-up turn can
    // hook up `getAllPara` if the client adopts that pattern.
    const single_parent = readParentQuery(ctx);

    if (deps.hasPool()) {
        if (single_parent.len > 0) {
            const ids = [_][]const u8{single_parent};
            const items = try model.listChildrenByParents(allocator, workspace_id, &ids);
            defer allocator.free(items);
            try response.ok(ctx, items);
            return;
        }
        try response.err(ctx, .bad_request, "parent_id is required", 40046);
        return;
    }

    if (single_parent.len == 0) {
        try response.err(ctx, .bad_request, "parent_id is required", 40046);
        return;
    }

    const children = try model.memListChildren(allocator, single_parent);
    defer allocator.free(children);

    var list: std.ArrayList(model.IssueResponse) = .empty;
    defer list.deinit(allocator);
    for (children) |c| try list.append(allocator, model.issueResponseFromEntry(c));
    try response.ok(ctx, list.items);
}

// ──────────────────────────────────────────────────────────────────────
// getMetadata / setMetadata
// ──────────────────────────────────────────────────────────────────────

pub fn getMetadata(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        const raw = model.selectIssueMetadataRaw(workspace_id, issue_id) orelse {
            try response.err(ctx, .not_found, "issue not found", 40410);
            return;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
            try response.err(ctx, .internal_server_error, "metadata_parse_failed", 50011);
            return;
        };
        defer parsed.deinit();
        try response.ok(ctx, model.GetMetadataResponse{
            .issue_id = issue_id,
            .metadata = parsed.value,
        });
        return;
    }

    const meta_ptr = model.memGetMetadata(issue_id) orelse {
        // No metadata for this issue yet — return an empty object so
        // the client always has a value to read.
        const empty_obj = try std.json.ObjectMap.init(ctx.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try response.ok(ctx, model.GetMetadataResponse{
            .issue_id = issue_id,
            .metadata = .{ .object = empty_obj },
        });
        return;
    };

    // Project the string→string map into a `std.json.Value` object.
    var obj = try std.json.ObjectMap.init(ctx.allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(ctx.allocator);
    var it = meta_ptr.iterator();
    while (it.next()) |kv| {
        try obj.put(ctx.allocator, kv.key_ptr.*, .{ .string = kv.value_ptr.* });
    }
    try response.ok(ctx, model.GetMetadataResponse{
        .issue_id = issue_id,
        .metadata = .{ .object = obj },
    });
}

pub fn setMetadata(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    const parsed = try validation.validateJson(model.SetMetadataRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.metadata != .object) {
        try response.err(ctx, .bad_request, "metadata must be an object", 40047);
        return;
    }

    if (deps.hasPool()) {
        const json_text = try std.json.Stringify.valueAlloc(ctx.allocator, req.metadata, .{});
        defer ctx.allocator.free(json_text);
        const new_raw = model.updateIssueMetadata(workspace_id, issue_id, json_text) orelse {
            try response.err(ctx, .not_found, "issue not found", 40410);
            return;
        };
        const resp_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, new_raw, .{}) catch {
            try response.err(ctx, .internal_server_error, "metadata_parse_failed", 50011);
            return;
        };
        defer resp_parsed.deinit();
        try response.ok(ctx, model.GetMetadataResponse{
            .issue_id = issue_id,
            .metadata = resp_parsed.value,
        });
        return;
    }

    // No-DB fallback: project into a string→string map.
    var map = std.StringHashMap([]const u8).init(model.memAlloc());
    errdefer map.deinit();
    var it = req.metadata.object.iterator();
    while (it.next()) |kv| {
        // We only persist primitive values; coerce non-primitives
        // back to their JSON string so the in-memory store stays
        // string-typed.
        const coerced: []const u8 = switch (kv.value_ptr.*) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(model.memAlloc(), "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(model.memAlloc(), "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            .null => "null",
            else => blk: {
                const text = try std.json.Stringify.valueAlloc(model.memAlloc(), kv.value_ptr.*, .{});
                break :blk text;
            },
        };
        try map.put(try model.memDup(kv.key_ptr.*), coerced);
    }
    try model.memSetMetadata(issue_id, map);

    var obj = try std.json.ObjectMap.init(ctx.allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(ctx.allocator);
    var sit = map.iterator();
    while (sit.next()) |kv| {
        try obj.put(ctx.allocator, kv.key_ptr.*, .{ .string = kv.value_ptr.* });
    }
    const meta_actor = resolveActor(ctx);
    publishIssueEvent(ctx.allocator, workspace_id, "issue_metadata:changed", meta_actor.actor_type, meta_actor.actor_id, issue_id);
    try response.ok(ctx, model.GetMetadataResponse{
        .issue_id = issue_id,
        .metadata = .{ .object = obj },
    });
}

// ──────────────────────────────────────────────────────────────────────
// Sub-resource / complex endpoints (labels, batches, children,
// timeline, subscribers, reactions, metadata keys, tasks, usage)
// ──────────────────────────────────────────────────────────────────────

const AttachLabelRequest = struct {
    label_id: []const u8 = "",
};

pub fn attachLabel(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(AttachLabelRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.label_id.len == 0) {
        try response.err(ctx, .bad_request, "missing label_id", 40021);
        return;
    }
    // Verify the label exists in the current workspace.
    if (deps.hasPool()) {
        const label_model = @import("../label/model.zig");
        if (label_model.dbGetLabel(workspace_id, req.label_id) == null) {
            try response.err(ctx, .not_found, "label not found", 40401);
            return;
        }
        _ = try model.dbAttachLabel(workspace_id, issue_id, req.label_id);
        try response.ok(ctx, .{ .issue_id = issue_id, .label_id = req.label_id, .attached = true });
        return;
    }
    {
        const label_model = @import("../label/model.zig");
        if (label_model.memFindLabel(req.label_id, workspace_id) == null) {
            try response.err(ctx, .not_found, "label not found", 40401);
            return;
        }
    }
    try model.memAttachLabel(issue_id, req.label_id);
    try response.ok(ctx, .{ .issue_id = issue_id, .label_id = req.label_id, .attached = true });
}

/// `GET /api/issues/:id/labels` — returns the full `LabelResponse`
/// list for the issue. Skips orphan label ids (label was deleted
/// while still attached) rather than erroring.
pub fn listIssueLabels(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        if (!model.issueExistsById(ctx.attributes.get("workspace_id") orelse "", issue_id)) {
            try response.err(ctx, .not_found, "issue not found", 40410);
            return;
        }
        const items = try model.dbListIssueLabels(allocator, issue_id);
        defer {
            for (items) |item| {
                const label_model = @import("../label/model.zig");
                label_model.freeLabelResponse(allocator, item);
            }
            allocator.free(items);
        }
        try response.ok(ctx, .{ .labels = items });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const label_model = @import("../label/model.zig");
    const label_service = @import("../label/service.zig");
    const ids = model.memListLabels(issue_id);
    var list: std.ArrayList(label_model.LabelResponse) = .empty;
    defer list.deinit(allocator);
    for (ids) |id| {
        const store = label_service.labelStore();
        if (label_model.memFindLabel(id, store.get(id).?.workspace_id)) |entry| {
            try list.append(allocator, label_model.labelResponseFromEntry(entry));
        }
    }
    try response.ok(ctx, .{ .labels = list.items });
}

pub fn detachLabel(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const label_id = try response.parseStringId(ctx, "labelId");

    if (deps.hasPool()) {
        if (model.dbDetachLabel(issue_id, label_id)) {
            try response.ok(ctx, .{ .issue_id = issue_id, .label_id = label_id, .detached = true });
        } else {
            try response.err(ctx, .not_found, "label not found", 40401);
        }
        return;
    }

    const removed = model.memDetachLabel(issue_id, label_id);
    if (removed) {
        try response.ok(ctx, .{ .issue_id = issue_id, .label_id = label_id, .detached = true });
    } else {
        try response.err(ctx, .not_found, "label not found", 40401);
    }
}

pub fn listAttachments(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const attachment_ids = model.memListAttachments(issue_id);
    try response.ok(ctx, .{ .data = attachment_ids });
}

const BatchUpdateRequest = struct {
    issue_ids: []const []const u8 = &.{},
    updates: model.Issue = .{
        .id = "",
        .title = "",
        .description = "",
        .project_id = "",
        .parent_id = "",
        .assignee_id = "",
        .state = "",
        .created_at = "",
        .updated_at = "",
        .squad_evaluated_at = null,
    },
};

pub fn batchUpdate(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try validation.validateJson(BatchUpdateRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    var updated: u32 = 0;

    if (deps.hasPool()) {
        for (req.issue_ids) |id| {
            if (model.batchUpdateIssueDB(
                id,
                workspace_id,
                req.updates.title,
                req.updates.description,
                req.updates.state,
                req.updates.project_id,
                req.updates.parent_id,
                req.updates.assignee_id,
            )) {
                updated += 1;
            }
        }
        try response.ok(ctx, .{ .updated = updated });
        return;
    }

    for (req.issue_ids) |id| {
        if (model.memFindIssue(id)) |existing| {
            var merged = existing;
            // memDup all request-body slices: the body is freed when
            // the handler returns, but the Issue lives in the
            // in-memory store.
            if (req.updates.title.len > 0) merged.title = try model.memDup(req.updates.title);
            if (req.updates.description.len > 0) merged.description = try model.memDup(req.updates.description);
            if (req.updates.state.len > 0) merged.state = try model.memDup(req.updates.state);
            if (req.updates.assignee_id.len > 0) merged.assignee_id = try model.memDup(req.updates.assignee_id);
            try model.memUpsertIssue(merged);
            updated += 1;
        }
    }
    try response.ok(ctx, .{ .updated = updated });
}

pub fn batchDelete(ctx: *zfinal.Context) !void {
    const parsed = try validation.validateJson(struct { issue_ids: []const []const u8 = &.{} }, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    var deleted: u32 = 0;
    for (req.issue_ids) |id| {
        if (model.memRemoveIssue(id)) deleted += 1;
    }
    try response.ok(ctx, .{ .deleted = deleted });
}

const QuickCreateRequest = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    assignee_id: []const u8 = "",
};

pub fn quickCreate(ctx: *zfinal.Context) !void {
    const parent_id = try response.parseStringId(ctx, "id");
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try validation.validateJson(QuickCreateRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.title.len == 0) {
        try response.err(ctx, .bad_request, "missing title", 40021);
        return;
    }

    if (deps.hasPool()) {
        if (model.insertIssue(
            workspace_id,
            req.title,
            req.description,
            "todo",
            "",
            parent_id,
            req.assignee_id,
        )) |resp| {
            // Record a timeline event so listTimeline can find it.
            const now_secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
            const now_str = try model.rfc3339(model.memAlloc(), now_secs);
            try model.memAddTimelineEvent(model.TimelineEvent{
                .id = try model.generateId(model.memAlloc(), "tl"),
                .issue_id = try model.memDup(parent_id),
                .event_type = "child_created",
                .actor_type = "user",
                .actor_id = "",
                .payload = "",
                .created_at = now_str,
            });
            ctx.res_status = .created;
            try response.ok(ctx, .{ .data = resp });
            return;
        }
        try response.err(ctx, .internal_server_error, "quick_create_failed", 50010);
        return;
    }

    const id = try model.generateId(model.memAlloc(), "issue");
    const now_secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const now_str = try model.rfc3339(model.memAlloc(), now_secs);
    const child = model.Issue{
        .id = id,
        .title = try model.memDup(req.title),
        .description = try model.memDup(req.description),
        .project_id = "",
        .parent_id = try model.memDup(parent_id),
        .assignee_id = try model.memDup(req.assignee_id),
        .state = "open",
        .created_at = now_str,
        .updated_at = now_str,
        .squad_evaluated_at = null,
    };
    try model.memUpsertIssue(child);
    // Record a timeline event so the parent shows the new child.
    try model.memAddTimelineEvent(model.TimelineEvent{
        .id = try model.generateId(model.memAlloc(), "tl"),
        .issue_id = parent_id,
        .event_type = "child_created",
        .actor_type = "user",
        .actor_id = "",
        .payload = "",
        .created_at = now_str,
    });
    try response.ok(ctx, .{ .data = child });
}

pub fn rerun(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        if (model.dbRerunIssue(workspace_id, issue_id)) |resp| {
            // Add timeline event to in-memory for listTimeline.
            const now_secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
            const now_str = try model.rfc3339(model.memAlloc(), now_secs);
            try model.memAddTimelineEvent(model.TimelineEvent{
                .id = try model.generateId(model.memAlloc(), "tl"),
                .issue_id = try model.memDup(issue_id),
                .event_type = "rerun",
                .actor_type = "user",
                .actor_id = "",
                .payload = "",
                .created_at = now_str,
            });
            try response.ok(ctx, .{ .data = resp });
        } else {
            try response.err(ctx, .not_found, "issue not found", 40401);
        }
        return;
    }

    const existing = model.memFindIssue(issue_id) orelse {
        try response.err(ctx, .not_found, "issue not found", 40401);
        return;
    };
    var reset = existing;
    reset.state = "open";
    reset.updated_at = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
    // rerun does not change squad_evaluated_at
    try model.memUpsertIssue(reset);
    try model.memAddTimelineEvent(model.TimelineEvent{
        .id = try model.generateId(model.memAlloc(), "tl"),
        .issue_id = issue_id,
        .event_type = "rerun",
        .actor_type = "user",
        .actor_id = "",
        .payload = "",
        .created_at = reset.updated_at,
    });
    try response.ok(ctx, .{ .data = reset });
}

pub fn childProgress(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");
    const children = try model.memListChildren(allocator, issue_id);
    defer allocator.free(children);
    var total: u32 = 0;
    var open: u32 = 0;
    var in_progress: u32 = 0;
    var done: u32 = 0;
    for (children) |child| {
        total += 1;
        if (std.mem.eql(u8, child.state, "open")) open += 1
        else if (std.mem.eql(u8, child.state, "in_progress")) in_progress += 1
        else if (std.mem.eql(u8, child.state, "done") or std.mem.eql(u8, child.state, "closed")) done += 1;
    }
    try response.ok(ctx, .{
        .issue_id = issue_id,
        .total = total,
        .open = open,
        .in_progress = in_progress,
        .done = done,
    });
}

pub fn groupedIssues(ctx: *zfinal.Context) !void {
    const it = model.mem_issues orelse {
        try response.ok(ctx, .{ .groups = &[_]struct { state: []const u8, count: u32 }{} });
        return;
    };
    var counts = std.StringHashMap(u32).init(model.memAlloc());
    defer counts.deinit();
    var issue_it = it.iterator();
    while (issue_it.next()) |kv| {
        const state = if (kv.value_ptr.*.state.len > 0) kv.value_ptr.*.state else "open";
        const gop = counts.getOrPut(state) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var groups: std.ArrayList(struct { state: []const u8, count: u32 }) = .empty;
    defer groups.deinit(model.memAlloc());
    var cit = counts.iterator();
    while (cit.next()) |kv| {
        groups.append(model.memAlloc(), .{ .state = kv.key_ptr.*, .count = kv.value_ptr.* }) catch continue;
    }
    try response.ok(ctx, .{ .groups = groups.items });
}

pub fn listChildren(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");
    const children = try model.memListChildren(allocator, issue_id);
    defer allocator.free(children);
    try response.ok(ctx, .{ .data = children });
}

pub fn listTimeline(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        // DB path: query activity_log for events on this issue.
        const db = model.borrowDb() orelse {
            try response.ok(ctx, .{ .data = &[_]model.TimelineEvent{} });
            return;
        };
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT id::text, issue_id::text, action, " ++
                "COALESCE(actor_type::text, 'system'), COALESCE(actor_id::text, ''), " ++
                "details::text, created_at " ++
                "FROM activity_log WHERE issue_id = $1::uuid ORDER BY created_at ASC",
            &[_]zfinal.SqlParam{.{ .text = issue_id }},
        ) catch {
            // Fall through to in-memory if activity_log query fails.
            const events = model.memListTimeline(issue_id);
            try response.ok(ctx, .{ .data = events });
            return;
        };
        defer rs.deinit();
        var out: std.ArrayList(model.TimelineEvent) = .empty;
        defer out.deinit(ctx.allocator);
        for (0..rs.rows.items.len) |i| {
            try out.append(ctx.allocator, .{
                .id = rs.rows.items[i].getText(0) orelse "",
                .issue_id = rs.rows.items[i].getText(1) orelse "",
                .event_type = rs.rows.items[i].getText(2) orelse "",
                .actor_type = rs.rows.items[i].getText(3) orelse "system",
                .actor_id = rs.rows.items[i].getText(4) orelse "",
                .payload = rs.rows.items[i].getText(5) orelse "",
                .created_at = rs.rows.items[i].getText(6) orelse "",
            });
        }
        // Also include in-memory timeline events for completeness.
        const mem_events = model.memListTimeline(issue_id);
        for (mem_events) |ev| {
            try out.append(ctx.allocator, ev);
        }
        try response.ok(ctx, .{ .data = out.items });
        return;
    }

    const events = model.memListTimeline(issue_id);
    try response.ok(ctx, .{ .data = events });
}

pub fn listSubscribers(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const entries = model.memListSubscribers(issue_id);
    try response.ok(ctx, .{ .data = entries });
}

const AddSubscriberRequest = struct {
    user_type: []const u8 = "user",
    user_id: []const u8 = "",
    reason: []const u8 = "manual",
};

pub fn addSubscriber(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(AddSubscriberRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.user_id.len == 0) {
        try response.err(ctx, .bad_request, "missing user_id", 40021);
        return;
    }
    // memDup every string field: the request body is freed when the
    // handler returns, but the in-memory SubscriberEntry lives for
    // the lifetime of the server. A later `removeSubscriber`
    // request iterates the list and compares `s.user_id` to a
    // fresh path-param slice; if `s.user_id` is a dangling
    // pointer, the comparison reads freed memory and the entry
    // looks "not found". The leak is acceptable for the no-DB path.
    const entry = model.SubscriberEntry{
        .issue_id = try model.memDup(issue_id),
        .user_type = try model.memDup(req.user_type),
        .user_id = try model.memDup(req.user_id),
        .reason = try model.memDup(req.reason),
        .created_at = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds()),
    };
    try model.memAddSubscriber(entry);
    if (model.getWorkspaceId(ctx)) |ws| {
        const sub_actor = resolveActor(ctx);
        publishIssueEvent(ctx.allocator, ws, "subscriber:added", sub_actor.actor_type, sub_actor.actor_id, issue_id);
    }
    try response.ok(ctx, .{ .data = entry });
}

pub fn removeSubscriber(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    // The `:userId` and `:userType` path segments carry the
    // subscriber identity. We default `user_type` to "user" when
    // not provided (the canonical case). Using path params
    // sidesteps zfinal's DELETE-body quirks described on the
    // route registration.
    var user_type: []const u8 = "user";
    if (ctx.getPathParam("userType")) |v| {
        if (v.len > 0) user_type = v;
    }
    const user_id = ctx.getPathParam("userId") orelse "";
    if (user_id.len == 0) {
        try response.err(ctx, .bad_request, "missing userId path param", 40021);
        return;
    }
    const removed = model.memRemoveSubscriber(issue_id, user_type, user_id);
    if (removed) {
        if (model.getWorkspaceId(ctx)) |ws| {
            const sub_actor = resolveActor(ctx);
            publishIssueEvent(ctx.allocator, ws, "subscriber:removed", sub_actor.actor_type, sub_actor.actor_id, issue_id);
        }
        try response.okNoContent(ctx);
    } else try response.err(ctx, .not_found, "subscriber not found", 40401);
}

pub fn listReactions(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const entries = model.memListReactions(issue_id);
    try response.ok(ctx, .{ .data = entries });
}

const AddReactionRequest = struct {
    actor_type: []const u8 = "user",
    actor_id: []const u8 = "",
    emoji: []const u8 = "",
};

pub fn addReaction(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(AddReactionRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.actor_id.len == 0) {
        try response.err(ctx, .bad_request, "missing actor_id", 40021);
        return;
    }
    if (req.emoji.len == 0) {
        try response.err(ctx, .bad_request, "missing emoji", 40021);
        return;
    }
    const id = try model.generateId(model.memAlloc(), "react");
    // memDup all request-body slices before storing: the body is
    // freed when the handler returns, but the ReactionEntry lives
    // in the in-memory store.
    const entry = model.ReactionEntry{
        .id = id,
        .issue_id = issue_id,
        .actor_type = try model.memDup(req.actor_type),
        .actor_id = try model.memDup(req.actor_id),
        .emoji = try model.memDup(req.emoji),
        .created_at = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds()),
    };
    try model.memAddReaction(entry);
    if (model.getWorkspaceId(ctx)) |ws| {
        const rx_actor = resolveActor(ctx);
        publishIssueEvent(ctx.allocator, ws, "issue_reaction:added", rx_actor.actor_type, rx_actor.actor_id, issue_id);
    }
    try response.ok(ctx, .{ .data = entry });
}

pub fn removeReaction(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const reaction_id = try response.parseStringId(ctx, "reactionId");
    const removed = model.memRemoveReaction(issue_id, reaction_id);
    if (removed) {
        if (model.getWorkspaceId(ctx)) |ws| {
            const rx_actor = resolveActor(ctx);
            publishIssueEvent(ctx.allocator, ws, "issue_reaction:removed", rx_actor.actor_type, rx_actor.actor_id, issue_id);
        }
        try response.okNoContent(ctx);
    } else try response.err(ctx, .not_found, "reaction not found", 40401);
}

pub fn squadEvaluated(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        // DB path: no squad_evaluated_at column yet, so just verify
        // the issue exists and return success.
        if (!model.issueExistsAny(issue_id)) {
            try response.err(ctx, .not_found, "issue not found", 40401);
            return;
        }
        if (model.getWorkspaceId(ctx)) |ws| {
            publishIssueEvent(allocator, ws, "squad_evaluated", "system", "squad", issue_id);
        }
        try response.ok(ctx, .{ .issue_id = issue_id, .evaluated = true });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40401);
        return;
    }

    // Ensure in-memory store is initialised so we can update the entry.
    try model.memInit();
    const existing_ptr = model.mem_issues.?.getPtr(issue_id) orelse {
        // Issue exists in DB but not in memory; create a minimal in-memory entry.
        const ws_id = model.getWorkspaceId(ctx) orelse "";
        const now_str2 = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
        const entry_new = model.Issue{
            .id = try model.memDup(issue_id),
            .title = "",
            .description = "",
            .project_id = "",
            .parent_id = "",
            .assignee_id = "",
            .state = "todo",
            .created_at = now_str2,
            .updated_at = now_str2,
            .squad_evaluated_at = try model.memDup(now_str2),
        };
        try model.memUpsertIssue(entry_new);
        if (ws_id.len > 0) {
            publishIssueEvent(allocator, ws_id, "squad_evaluated", "system", "squad", issue_id);
        }
        try response.ok(ctx, .{ .issue_id = issue_id, .evaluated = true });
        return;
    };
    const now_str = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds());
    existing_ptr.squad_evaluated_at = try model.memDup(now_str);
    try model.memAddTimelineEvent(model.TimelineEvent{
        .id = try model.generateId(model.memAlloc(), "tl"),
        .issue_id = issue_id,
        .event_type = "squad_evaluated",
        .actor_type = "system",
        .actor_id = "squad",
        .payload = "",
        .created_at = now_str,
    });
    if (model.getWorkspaceId(ctx)) |ws| {
        publishIssueEvent(allocator, ws, "squad_evaluated", "system", "squad", issue_id);
    }
    try response.ok(ctx, .{ .issue_id = issue_id, .evaluated = true, .data = existing_ptr.* });
}

// ──────────────────────────────────────────────────────────────────────
// new endpoints: comment trigger preview, active-task, task-runs,
// usage, pull-requests, per-key metadata, subscribe, unsubscribe,
// remove-reaction-by-emoji
// ──────────────────────────────────────────────────────────────────────

/// `POST /api/issues/:id/comments/trigger-preview`
///
/// No-DB behaviour: scan the comment body for any `@<id>` token,
/// then add the issue's current agent-assignee (if any) as a
/// "issue_assignee" trigger. Returns an empty `agents` list when
/// the body is empty or contains no agent mentions.
pub fn previewCommentTriggers(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(model.CommentTriggerPreviewRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    var out: std.ArrayList(model.CommentTriggerAgentResponse) = .empty;
    defer out.deinit(allocator);

    if (deps.hasPool()) {
        // DB path: query issue assignee and scan @mentions in content.
        if (model.selectIssueById(ctx.attributes.get("workspace_id") orelse "", issue_id)) |resp| {
            if (resp.assignee_id) |aid| {
                if (aid.len > 0) {
                    const at = resp.assignee_type orelse "agent";
                    if (std.mem.eql(u8, at, "agent")) {
                        try out.append(allocator, .{
                            .id = try allocator.dupe(u8, aid),
                            .name = "Assignee",
                            .source = "issue_assignee",
                            .reason = "Issue assignee",
                        });
                    }
                }
            }
        }
        // Scan for @mentions in content (same logic as no-DB path).
        var i: usize = 0;
        while (i < req.content.len) {
            while (i < req.content.len and (req.content[i] == ' ' or req.content[i] == '\n' or req.content[i] == '\t' or req.content[i] == ',')) : (i += 1) {}
            const start = i;
            while (i < req.content.len and req.content[i] != ' ' and req.content[i] != '\n' and req.content[i] != '\t' and req.content[i] != ',') : (i += 1) {}
            if (i == start) continue;
            var token = req.content[start..i];
            if (token.len > 0 and token[0] == '@') token = token[1..];
            if (token.len == 0) continue;
            var alnum = true;
            for (token) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
                alnum = false;
                break;
            };
            if (!alnum) continue;
            try out.append(allocator, .{
                .id = try allocator.dupe(u8, token),
                .name = try std.fmt.allocPrint(allocator, "agent {s}", .{token}),
                .source = "mention_agent",
                .reason = "Mentioned in comment",
            });
        }
        try response.ok(ctx, model.CommentTriggerPreviewResponse{ .agents = out.items });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }

    // (1) issue assignee, when it's an agent.
    if (model.memFindIssue(issue_id)) |issue| {
        if (issue.assignee_id.len > 0) {
            const t = issue.assignee_type orelse "agent";
            if (std.mem.eql(u8, t, "agent")) {
                try out.append(allocator, .{
                    .id = try model.memDup(issue.assignee_id),
                    .name = "Assignee",
                    .source = "issue_assignee",
                    .reason = "Issue assignee",
                });
            }
        }
    }

    // (2) `@<id>` mentions in the body. Tokenise on whitespace and
    // any leading `@` is stripped.
    var i: usize = 0;
    while (i < req.content.len) {
        while (i < req.content.len and (req.content[i] == ' ' or req.content[i] == '\n' or req.content[i] == '\t' or req.content[i] == ',')) : (i += 1) {}
        const start = i;
        while (i < req.content.len and req.content[i] != ' ' and req.content[i] != '\n' and req.content[i] != '\t' and req.content[i] != ',') : (i += 1) {}
        if (i == start) continue;
        var token = req.content[start..i];
        if (token.len > 0 and token[0] == '@') token = token[1..];
        if (token.len == 0) continue;
        // Only treat alphanumerics/dashes as IDs to avoid catching
        // punctuation noise.
        var alnum = true;
        for (token) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
            alnum = false;
            break;
        };
        if (!alnum) continue;
        try out.append(allocator, .{
            .id = try model.memDup(token),
            .name = try std.fmt.allocPrint(allocator, "agent {s}", .{token}),
            .source = "mention_agent",
            .reason = "Mentioned in comment",
        });
    }

    try response.ok(ctx, model.CommentTriggerPreviewResponse{ .agents = out.items });
}

/// `GET /api/issues/:id/active-task` — returns the wrapped
/// `{tasks:[...]}` list of in-flight tasks. Returns an empty `tasks`
/// array when the issue is missing or has no active tasks.
pub fn activeTask(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        const db = model.borrowDb() orelse {
            try response.ok(ctx, .{ .tasks = &[_]model.TaskResponse{} });
            return;
        };
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT id::text, issue_id::text, status, created_at " ++
                "FROM agent_task_queue WHERE issue_id = $1::uuid " ++
                "AND status IN ('queued','dispatched','running','waiting_local_directory')",
            &[_]zfinal.SqlParam{.{ .text = issue_id }},
        ) catch {
            try response.ok(ctx, .{ .tasks = &[_]model.TaskResponse{} });
            return;
        };
        defer rs.deinit();
        var out: std.ArrayList(model.TaskResponse) = .empty;
        defer out.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try out.append(allocator, .{
                .id = rs.rows.items[i].getText(0) orelse "",
                .issue_id = rs.rows.items[i].getText(1) orelse "",
                .status = rs.rows.items[i].getText(2) orelse "",
                .created_at = rs.rows.items[i].getText(3) orelse "",
            });
        }
        try response.ok(ctx, .{ .tasks = out.items });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const all = model.memListTasks(issue_id);
    var out: std.ArrayList(model.TaskResponse) = .empty;
    defer out.deinit(allocator);
    for (all) |t| {
        if (isActiveTaskStatus(t.status)) {
            try out.append(allocator, .{
                .id = t.id,
                .issue_id = t.issue_id,
                .status = t.status,
                .created_at = t.created_at,
            });
        }
    }
    try response.ok(ctx, .{ .tasks = out.items });
}

fn isActiveTaskStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "queued") or
        std.mem.eql(u8, status, "dispatched") or
        std.mem.eql(u8, status, "running") or
        std.mem.eql(u8, status, "waiting_local_directory");
}

/// `GET /api/issues/:id/task-runs` — bare array of all tasks.
pub fn taskRuns(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        const db = model.borrowDb() orelse {
            try response.ok(ctx, &[_]model.TaskResponse{});
            return;
        };
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT id::text, issue_id::text, status, created_at " ++
                "FROM agent_task_queue WHERE issue_id = $1::uuid",
            &[_]zfinal.SqlParam{.{ .text = issue_id }},
        ) catch {
            try response.ok(ctx, &[_]model.TaskResponse{});
            return;
        };
        defer rs.deinit();
        var out: std.ArrayList(model.TaskResponse) = .empty;
        defer out.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try out.append(allocator, .{
                .id = rs.rows.items[i].getText(0) orelse "",
                .issue_id = rs.rows.items[i].getText(1) orelse "",
                .status = rs.rows.items[i].getText(2) orelse "",
                .created_at = rs.rows.items[i].getText(3) orelse "",
            });
        }
        try response.ok(ctx, out.items);
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const all = model.memListTasks(issue_id);
    var out: std.ArrayList(model.TaskResponse) = .empty;
    defer out.deinit(allocator);
    for (all) |t| try out.append(allocator, .{
        .id = t.id,
        .issue_id = t.issue_id,
        .status = t.status,
        .created_at = t.created_at,
    });
    try response.ok(ctx, out.items);
}

/// `GET /api/issues/:id/usage` — aggregate token totals across
/// every task belonging to this issue.
pub fn issueUsage(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        const db = model.borrowDb() orelse {
            try response.ok(ctx, model.IssueUsageResponse{
                .total_input_tokens = 0, .total_output_tokens = 0,
                .total_cache_read_tokens = 0, .total_cache_write_tokens = 0,
                .task_count = 0,
            });
            return;
        };
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT COALESCE(SUM(tu.input_tokens), 0), COALESCE(SUM(tu.output_tokens), 0), " ++
                "COALESCE(SUM(tu.cache_read_tokens), 0), COALESCE(SUM(tu.cache_write_tokens), 0), " ++
                "COUNT(DISTINCT atq.id) " ++
                "FROM agent_task_queue atq LEFT JOIN task_usage tu ON tu.task_id = atq.id " ++
                "WHERE atq.issue_id = $1::uuid",
            &[_]zfinal.SqlParam{.{ .text = issue_id }},
        ) catch {
            try response.ok(ctx, model.IssueUsageResponse{
                .total_input_tokens = 0, .total_output_tokens = 0,
                .total_cache_read_tokens = 0, .total_cache_write_tokens = 0,
                .task_count = 0,
            });
            return;
        };
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            try response.ok(ctx, model.IssueUsageResponse{
                .total_input_tokens = 0, .total_output_tokens = 0,
                .total_cache_read_tokens = 0, .total_cache_write_tokens = 0,
                .task_count = 0,
            });
            return;
        }
        try response.ok(ctx, model.IssueUsageResponse{
            .total_input_tokens = std.fmt.parseInt(i64, rs.rows.items[0].getText(0) orelse "0", 10) catch 0,
            .total_output_tokens = std.fmt.parseInt(i64, rs.rows.items[0].getText(1) orelse "0", 10) catch 0,
            .total_cache_read_tokens = std.fmt.parseInt(i64, rs.rows.items[0].getText(2) orelse "0", 10) catch 0,
            .total_cache_write_tokens = std.fmt.parseInt(i64, rs.rows.items[0].getText(3) orelse "0", 10) catch 0,
            .task_count = @intCast(std.fmt.parseInt(i64, rs.rows.items[0].getText(4) orelse "0", 10) catch 0),
        });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const all = model.memListTasks(issue_id);
    var total_in: i64 = 0;
    var total_out: i64 = 0;
    var cache_read: i64 = 0;
    var cache_write: i64 = 0;
    for (all) |t| {
        total_in += t.input_tokens;
        total_out += t.output_tokens;
        cache_read += t.cache_read_tokens;
        cache_write += t.cache_write_tokens;
    }
    _ = allocator;
    try response.ok(ctx, model.IssueUsageResponse{
        .total_input_tokens = total_in,
        .total_output_tokens = total_out,
        .total_cache_read_tokens = cache_read,
        .total_cache_write_tokens = cache_write,
        .task_count = @intCast(all.len),
    });
}

/// `GET /api/issues/:id/pull-requests` — wrapped list of linked PRs.
pub fn pullRequests(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");

    if (deps.hasPool()) {
        const db = model.borrowDb() orelse {
            try response.ok(ctx, .{ .pull_requests = &[_]model.PullRequestResponse{} });
            return;
        };
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT gpr.id::text, gpr.pr_number, gpr.title, gpr.state, " ++
                "gpr.repo_owner, gpr.repo_name, gpr.html_url, " ++
                "gpr.author_login, gpr.pr_created_at, gpr.pr_updated_at " ++
                "FROM github_pull_request gpr " ++
                "JOIN issue_pull_request ipr ON gpr.id = ipr.pull_request_id " ++
                "WHERE ipr.issue_id = $1::uuid",
            &[_]zfinal.SqlParam{.{ .text = issue_id }},
        ) catch {
            try response.ok(ctx, .{ .pull_requests = &[_]model.PullRequestResponse{} });
            return;
        };
        defer rs.deinit();
        var out: std.ArrayList(model.PullRequestResponse) = .empty;
        defer out.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try out.append(allocator, .{
                .id = rs.rows.items[i].getText(0) orelse "",
                .number = std.fmt.parseInt(i32, rs.rows.items[i].getText(1) orelse "0", 10) catch 0,
                .title = rs.rows.items[i].getText(2) orelse "",
                .state = rs.rows.items[i].getText(3) orelse "",
                .repo_owner = rs.rows.items[i].getText(4) orelse "",
                .repo_name = rs.rows.items[i].getText(5) orelse "",
                .html_url = rs.rows.items[i].getText(6) orelse "",
                .author_login = rs.rows.items[i].getText(7) orelse "",
                .pr_created_at = rs.rows.items[i].getText(8) orelse "",
                .pr_updated_at = rs.rows.items[i].getText(9) orelse "",
            });
        }
        try response.ok(ctx, .{ .pull_requests = out.items });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const all = model.memListPullRequests(issue_id);
    var out: std.ArrayList(model.PullRequestResponse) = .empty;
    defer out.deinit(allocator);
    for (all) |pr| try out.append(allocator, .{
        .id = pr.id,
        .number = pr.number,
        .title = pr.title,
        .state = pr.state,
        .repo_owner = pr.repo_owner,
        .repo_name = pr.repo_name,
        .html_url = pr.html_url,
        .author_login = pr.author_login,
        .pr_created_at = pr.pr_created_at,
        .pr_updated_at = pr.pr_updated_at,
    });
    try response.ok(ctx, .{ .pull_requests = out.items });
}

/// Validate that a metadata key matches the Go server's regex:
/// `^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$`. Returns `true` when valid.
fn isValidMetadataKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    const first = key[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    return true;
}

/// Encode a primitive JSON value back to a string for the
/// in-memory `StringHashMap` store. The no-DB path clamps to a
/// string-typed metadata map (matches the legacy storage layout).
fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| if (b) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false"),
        .null => try allocator.dupe(u8, "null"),
        else => try std.json.Stringify.valueAlloc(allocator, v, .{}),
    };
}

/// Project the in-memory metadata map back to a `std.json.Value`
/// object whose values are `string`s (matches the no-DB store
/// type).
fn metadataObjectFromMap(allocator: std.mem.Allocator, m: *const std.StringHashMap([]const u8)) !std.json.Value {
    var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer obj.deinit(allocator);
    var it = m.iterator();
    while (it.next()) |kv| {
        try obj.put(allocator, kv.key_ptr.*, .{ .string = kv.value_ptr.* });
    }
    return .{ .object = obj };
}

/// Project a `StringHashMap([]const u8)` metadata store to a JSON
/// object allocated on `allocator`. Caller owns the returned
/// `std.json.Value`.
fn metadataObjectFromAny(allocator: std.mem.Allocator, m: *const std.StringHashMap(std.StringHashMap([]const u8)), issue_id: []const u8) !std.json.Value {
    const inner = m.getPtr(issue_id) orelse {
        const empty = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        return .{ .object = empty };
    };
    return metadataObjectFromMap(allocator, inner);
}

/// `PUT /api/issues/:id/metadata/:key` — set a single metadata key.
/// Rejects null/array/object values, validates the key shape, and
/// enforces the 50-key / 8KB size limits.
pub fn setMetadataKey(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);
    const issue_id = try response.parseStringId(ctx, "id");
    const key = (try requirePathParam(ctx, "key")) orelse return;
    if (!isValidMetadataKey(key)) {
        try response.err(ctx, .bad_request, "invalid metadata key", 40047);
        return;
    }
    const parsed = try validation.validateJson(model.SetMetadataKeyRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    switch (req.value) {
        .null => {
            try response.err(ctx, .bad_request, "value cannot be null (use DELETE to remove a key)", 40047);
            return;
        },
        .array, .object => {
            try response.err(ctx, .bad_request, "value must be a primitive: string, number, or bool", 40047);
            return;
        },
        else => {},
    }

    if (deps.hasPool()) {
        // Read current metadata, update the key, write back.
        const raw = model.selectIssueMetadataRaw(workspace_id, issue_id) orelse {
            try response.err(ctx, .not_found, "issue not found", 40410);
            return;
        };
        var current = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
            try response.err(ctx, .internal_server_error, "metadata_parse_failed", 50011);
            return;
        };
        defer current.deinit();
        // Ensure it's an object.
        if (current.value != .object) {
            // Replace with a fresh empty object.
            current.deinit();
            current = std.json.Parsed(std.json.Value){
                .arena = undefined,
                .value = .{ .object = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch {
                    try response.err(ctx, .internal_server_error, "metadata_parse_failed", 50011);
                    return;
                } },
            };
        }
        // Update the key.
        const json_value = switch (req.value) {
            .string => |s| std.json.Value{ .string = s },
            .integer => |i| std.json.Value{ .integer = i },
            .float => |f| std.json.Value{ .float = f },
            .bool => |b| std.json.Value{ .bool = b },
            else => unreachable,
        };
        current.value.object.put(allocator, try allocator.dupe(u8, key), json_value) catch {
            try response.err(ctx, .internal_server_error, "metadata_update_failed", 50012);
            return;
        };
        // Write back.
        const json_text = std.json.Stringify.valueAlloc(allocator, current.value, .{}) catch {
            try response.err(ctx, .internal_server_error, "metadata_serialize_failed", 50013);
            return;
        };
        defer allocator.free(json_text);
        _ = model.updateIssueMetadata(workspace_id, issue_id, json_text) orelse {
            try response.err(ctx, .internal_server_error, "metadata_write_failed", 50014);
            return;
        };
        if (model.getWorkspaceId(ctx)) |ws| {
            const meta_actor = resolveActor(ctx);
            publishIssueEvent(allocator, ws, "issue_metadata:changed", meta_actor.actor_type, meta_actor.actor_id, issue_id);
        }
        try response.ok(ctx, model.GetMetadataResponse{ .issue_id = issue_id, .metadata = current.value });
        return;
    }

    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    // Confirm issue exists.
    if (model.mem_issues.?.getPtr(issue_id) == null) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }

    const stable_key = try model.memDup(key);
    errdefer model.memAlloc().free(stable_key);
    const stable_id = try model.memDup(issue_id);
    errdefer model.memAlloc().free(stable_id);

    const gop = try model.mem_metadata.?.getOrPut(stable_id);
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(model.memAlloc());

    // Enforce the 50-key cap.
    if (!gop.value_ptr.contains(stable_key) and gop.value_ptr.count() >= 50) {
        try response.err(ctx, .bad_request, "metadata cannot exceed 50 keys", 40047);
        return;
    }

    const stored = try jsonValueToString(model.memAlloc(), req.value);
    try gop.value_ptr.put(stable_key, stored);

    // Best-effort 8KB size cap: serialise the projected object and
    // reject oversize.
    const projected = try metadataObjectFromMap(model.memAlloc(), gop.value_ptr);
    const text = try std.json.Stringify.valueAlloc(model.memAlloc(), projected, .{});
    if (text.len > 8 * 1024) {
        try response.err(ctx, .bad_request, "metadata exceeds the 8KB size limit", 40047);
        return;
    }

    const meta_key_actor = resolveActor(ctx);
    publishIssueEvent(allocator, workspace_id, "issue_metadata:changed", meta_key_actor.actor_type, meta_key_actor.actor_id, issue_id);

    if (model.mem_metadata) |*m| {
        const out = try metadataObjectFromAny(allocator, m, issue_id);
        try response.ok(ctx, model.GetMetadataResponse{
            .issue_id = issue_id,
            .metadata = out,
        });
        return;
    }
    const empty = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try response.ok(ctx, model.GetMetadataResponse{
        .issue_id = issue_id,
        .metadata = .{ .object = empty },
    });
}

/// `DELETE /api/issues/:id/metadata/:key` — remove a single
/// metadata key. Missing keys are a no-op (200).
pub fn deleteMetadataKey(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const issue_id = try response.parseStringId(ctx, "id");
    const key = (try requirePathParam(ctx, "key")) orelse return;
    if (!isValidMetadataKey(key)) {
        try response.err(ctx, .bad_request, "invalid metadata key", 40047);
        return;
    }
    try model.memInit();
    try model.mem_mutex.lock(zfinal.io_instance.io);
    defer model.mem_mutex.unlock(zfinal.io_instance.io);

    if (model.mem_metadata) |*m| {
        if (m.getPtr(issue_id)) |inner| {
            _ = inner.remove(key);
        }
    }
    if (model.getWorkspaceId(ctx)) |ws| {
        const meta_del_actor = resolveActor(ctx);
        publishIssueEvent(allocator, ws, "issue_metadata:changed", meta_del_actor.actor_type, meta_del_actor.actor_id, issue_id);
    }
    if (model.mem_metadata) |*m| {
        const out = try metadataObjectFromAny(allocator, m, issue_id);
        try response.ok(ctx, model.GetMetadataResponse{
            .issue_id = issue_id,
            .metadata = out,
        });
        return;
    }
    const empty = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try response.ok(ctx, model.GetMetadataResponse{
        .issue_id = issue_id,
        .metadata = .{ .object = empty },
    });
}

const SubscribeRequest = struct {
    user_id: ?[]const u8 = null,
    user_type: ?[]const u8 = null,
};

fn resolveSubscribeTarget(ctx: *zfinal.Context, req: SubscribeRequest) struct { user_type: []const u8, user_id: []const u8 } {
    const caller = currentUserId(ctx);
    return .{
        .user_type = req.user_type orelse "user",
        .user_id = req.user_id orelse caller,
    };
}

/// `POST /api/issues/:id/subscribe` — self- or explicit-target
/// subscribe. Idempotent. Returns `{subscribed:true}`.
pub fn subscribeIssue(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(SubscribeRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    const target = resolveSubscribeTarget(ctx, req);
    if (target.user_id.len == 0) {
        try response.err(ctx, .bad_request, "missing user_id", 40021);
        return;
    }

    if (deps.hasPool()) {
        const db = model.borrowDb() orelse {
            try response.ok(ctx, model.SubscribeResponse{ .subscribed = true });
            return;
        };
        defer deps.releaseBack(db);
        _ = db.queryParams(
            "INSERT INTO issue_subscriber (issue_id, user_type, user_id, reason) " ++
                "VALUES ($1::uuid, $2, $3::uuid, 'manual') " ++
                "ON CONFLICT (issue_id, user_type, user_id) DO NOTHING",
            &[_]zfinal.SqlParam{
                .{ .text = issue_id },
                .{ .text = target.user_type },
                .{ .text = target.user_id },
            },
        ) catch {};
        if (model.getWorkspaceId(ctx)) |ws| {
            const sub_actor = resolveActor(ctx);
            publishIssueEvent(ctx.allocator, ws, "subscriber:added", sub_actor.actor_type, sub_actor.actor_id, issue_id);
        }
        try response.ok(ctx, model.SubscribeResponse{ .subscribed = true });
        return;
    }

    if (!model.issueExistsAny(issue_id)) {
        try response.err(ctx, .not_found, "issue not found", 40410);
        return;
    }
    const entry = model.SubscriberEntry{
        .issue_id = try model.memDup(issue_id),
        .user_type = try model.memDup(target.user_type),
        .user_id = try model.memDup(target.user_id),
        .reason = try model.memDup("manual"),
        .created_at = try model.rfc3339(model.memAlloc(), std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds()),
    };
    try model.memAddSubscriber(entry);
    if (model.getWorkspaceId(ctx)) |ws| {
        const sub_actor = resolveActor(ctx);
        publishIssueEvent(ctx.allocator, ws, "subscriber:added", sub_actor.actor_type, sub_actor.actor_id, issue_id);
    }
    try response.ok(ctx, model.SubscribeResponse{ .subscribed = true });
}

/// `POST /api/issues/:id/unsubscribe` — matching counterpart to
/// subscribe. Missing subscriptions are a no-op (still 200).
pub fn unsubscribeIssue(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(SubscribeRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    const target = resolveSubscribeTarget(ctx, req);
    if (target.user_id.len == 0) {
        try response.err(ctx, .bad_request, "missing user_id", 40021);
        return;
    }
    _ = model.memRemoveSubscriber(issue_id, target.user_type, target.user_id);
    if (model.getWorkspaceId(ctx)) |ws| {
        const sub_actor = resolveActor(ctx);
        publishIssueEvent(ctx.allocator, ws, "subscriber:removed", sub_actor.actor_type, sub_actor.actor_id, issue_id);
    }
    try response.ok(ctx, model.SubscribeResponse{ .subscribed = false });
}

/// `DELETE /api/issues/:id/reactions` (no path param) — Go-style
/// body-based removal. The body carries `{emoji}` and the match is
/// `(issue_id, actor_type, actor_id, emoji)`.
pub fn removeReactionByEmoji(ctx: *zfinal.Context) !void {
    const issue_id = try response.parseStringId(ctx, "id");
    const parsed = try validation.validateJson(model.RemoveReactionRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.emoji.len == 0) {
        try response.err(ctx, .bad_request, "missing emoji", 40021);
        return;
    }
    const actor_id = currentUserId(ctx);
    if (actor_id.len == 0) {
        try response.err(ctx, .unauthorized, "missing user", 40110);
        return;
    }
    const removed = model.memRemoveReactionByTuple(issue_id, "user", actor_id, req.emoji);
    if (removed) {
        if (model.getWorkspaceId(ctx)) |ws| {
            const rx_actor = resolveActor(ctx);
            publishIssueEvent(ctx.allocator, ws, "issue_reaction:removed", rx_actor.actor_type, rx_actor.actor_id, issue_id);
        }
        try response.okNoContent(ctx);
    } else try response.err(ctx, .not_found, "reaction not found", 40401);
}
