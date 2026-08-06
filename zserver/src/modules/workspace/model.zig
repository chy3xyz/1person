//! Workspace module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape + request/response DTOs) and
//! any escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic and the no-DB fallback path.
//!
//! The `workspace` / `member` / `workspace_invitation` tables use UUID
//! PKs with JSONB columns (`workspace.settings`, `workspace.repos`)
//! and the `member` row has a foreign key to `user`, so all SQL goes
//! through `zfinal.SqlParam` via `deps.acquire()`. The in-memory
//! fallback uses the `WorkspaceEntry` / `MemberEntry` /
//! `InvitationEntry` structs defined here so the smoke-test path is
//! exercised when the DB is unconfigured.
//!
//! The `WorkspaceEntry` / `MemberEntry` / `InvitationResponse` /
//! `MemberResponse` types and the `memAddMember` /
//! `memGetWorkspaceName` / `resolveSlug` helpers are part of the
//! module's public surface: they are re-imported by the
//! `src/modules/invitation/service.zig` and
//! `src/modules/realtime/service.zig` siblings. `handler.zig` exposes
//! them as `pub const` aliases to keep the existing import sites
//! working without modification.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

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

/// Format an `i64` as a string for the in-memory timestamp columns.
pub fn memFmtNumber(n: i64) ![]const u8 {
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{n});
}

/// Stable pseudo-UUID for the in-memory store. Used by the
/// integration / invitation fallback paths.
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

/// `generateId` flavour that namespaces by `slug:user_id` so workspace
/// ids stay unique per creator.
pub fn memGenerateId(allocator: std.mem.Allocator, slug: []const u8, user_id: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ slug, user_id, ns });
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
pub var mem_workspaces: ?std.StringHashMap(WorkspaceEntry) = null;
pub var mem_members: ?std.StringHashMap(std.ArrayList(MemberEntry)) = null;
pub var mem_invitations: ?std.StringHashMap(InvitationEntry) = null;
pub var mem_github_installs: ?std.StringHashMap(GithubInstallationEntry) = null;
pub var mem_lark_installs: ?std.StringHashMap(LarkInstallationEntry) = null;
pub var mem_lark_sessions: ?std.StringHashMap(LarkInstallSession) = null;
pub var mem_workspace_limits: ?std.StringHashMap(WorkspaceLimit) = null;

/// Lazy initialiser for the in-memory maps. Safe to call repeatedly.
pub fn memInit() !void {
    if (mem_workspaces == null) {
        mem_workspaces = std.StringHashMap(WorkspaceEntry).init(memAlloc());
        mem_members = std.StringHashMap(std.ArrayList(MemberEntry)).init(memAlloc());
        mem_invitations = std.StringHashMap(InvitationEntry).init(memAlloc());
        mem_github_installs = std.StringHashMap(GithubInstallationEntry).init(memAlloc());
        mem_lark_installs = std.StringHashMap(LarkInstallationEntry).init(memAlloc());
        mem_lark_sessions = std.StringHashMap(LarkInstallSession).init(memAlloc());
        mem_workspace_limits = std.StringHashMap(WorkspaceLimit).init(memAlloc());
    }
}

// ──────────────────────────────────────────────────────────────────────
// in-memory row structs
// ──────────────────────────────────────────────────────────────────────

/// In-memory `workspace` row.
pub const WorkspaceEntry = struct {
    id: []const u8,
    name: []const u8,
    slug: []const u8,
    description: []const u8,
    context: []const u8,
    issue_prefix: []const u8,
    avatar_url: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    owner_id: []const u8,
    parent_id: []const u8,
};

/// In-memory `member` row.
pub const MemberEntry = struct {
    user_id: []const u8,
    role: []const u8,
    name: []const u8,
    email: []const u8,
};

/// Per-workspace limits for multi-tenancy V2.
pub const WorkspaceLimit = struct {
    max_members: ?i64,
    max_storage: ?i64,
    max_api_calls: ?i64,
};

/// In-memory `workspace_invitation` row.
pub const InvitationEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    inviter_id: []const u8,
    invitee_email: []const u8,
    role: []const u8,
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    expires_at: []const u8,
};

/// In-memory `github_installation` row.
pub const GithubInstallationEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    installation_id: []const u8,
    account_login: []const u8,
    account_url: []const u8,
    repository_selection: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `lark_installation` row.
pub const LarkInstallationEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    app_id: []const u8,
    tenant_key: []const u8,
    tenant_name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `lark_install_session` row.
pub const LarkInstallSession = struct {
    id: []const u8,
    workspace_id: []const u8,
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

/// Request body for `POST /api/workspaces`.
pub const CreateWorkspaceRequest = struct {
    name: []const u8,
    slug: []const u8,
    description: ?[]const u8 = null,
    context: ?[]const u8 = null,
    issue_prefix: ?[]const u8 = null,
};

/// Request body for `PATCH /api/workspaces/:id` and `PUT /api/workspaces/:id`.
pub const UpdateWorkspaceRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    context: ?[]const u8 = null,
    settings: ?std.json.Value = null,
    repos: ?std.json.Value = null,
    issue_prefix: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
};

/// Request body for `POST /api/workspaces/:id/members` and the
/// `POST /api/workspaces/:id/invitations` endpoint.
pub const CreateMemberRequest = struct {
    email: []const u8,
    role: []const u8 = "member",
};

/// Request body for `PATCH /api/workspaces/:id/members/:memberId`.
pub const UpdateMemberRequest = struct {
    role: []const u8,
};

/// Request body for `GET /api/workspaces/:id/github/connect`.
pub const ConnectGithubRequest = struct {
    installation_id: []const u8,
    account_login: ?[]const u8 = null,
    account_url: ?[]const u8 = null,
    repository_selection: ?[]const u8 = null,
};

/// Request body for `POST /api/workspaces/:id/github/connect`.
pub const ConnectGithubInstallationRequest = struct {
    installation_id: []const u8,
    account_login: ?[]const u8 = null,
    account_url: ?[]const u8 = null,
    repository_selection: ?[]const u8 = null,
};

/// Request body for `POST /api/workspaces/:id/lark/connect`.
pub const ConnectLarkRequest = struct {
    app_id: []const u8,
    tenant_key: []const u8,
    tenant_name: ?[]const u8 = null,
};

/// Request body for `POST /api/workspaces/children` (multi-tenancy V2).
pub const CreateChildWorkspaceRequest = struct {
    parent_id: []const u8,
    name: []const u8,
    slug: []const u8,
    description: ?[]const u8 = null,
    context: ?[]const u8 = null,
    issue_prefix: ?[]const u8 = null,
};

/// Request body for `PUT /api/workspaces/:id/limits`.
pub const SetLimitRequest = struct {
    max_members: ?i64 = null,
    max_storage: ?i64 = null,
    max_api_calls: ?i64 = null,
};

// ──────────────────────────────────────────────────────────────────────
// response DTOs
// ──────────────────────────────────────────────────────────────────────

/// `workspace` row, projected for the API. Used by both DB and
/// in-memory paths so the smoke test exercises the same wire shape.
pub const WorkspaceResponse = struct {
    id: []const u8,
    name: []const u8,
    slug: []const u8,
    description: ?[]const u8,
    context: ?[]const u8,
    settings: ?std.json.Value,
    repos: ?std.json.Value,
    issue_prefix: []const u8,
    avatar_url: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// `member` row joined with the corresponding `user` row, projected
/// for the API. The `id` column is the `member.id`; the human-readable
/// `name` / `email` / `avatar_url` come from `user`.
pub const MemberResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    user_id: []const u8,
    role: []const u8,
    created_at: []const u8,
    name: []const u8,
    email: []const u8,
    avatar_url: ?[]const u8,
};

/// `workspace_invitation` row, joined with inviter user info.
pub const InvitationResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8 = "",
    inviter_id: []const u8,
    invitee_email: []const u8,
    invitee_user_id: ?[]const u8,
    role: []const u8,
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    expires_at: []const u8,
    inviter_name: []const u8,
    inviter_email: []const u8,
};

/// `github_installation` row, projected for the API.
pub const GithubInstallationResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    installation_id: []const u8,
    account_login: []const u8,
    account_url: []const u8,
    repository_selection: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// `lark_installation` row, projected for the API.
pub const LarkInstallationResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    app_id: []const u8,
    tenant_key: []const u8,
    tenant_name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// pure helpers
// ──────────────────────────────────────────────────────────────────────

/// Map a `member.role` string to a numeric rank (owner > admin > member).
pub fn roleRank(role: []const u8) u8 {
    if (std.mem.eql(u8, role, "owner")) return 3;
    if (std.mem.eql(u8, role, "admin")) return 2;
    if (std.mem.eql(u8, role, "member")) return 1;
    return 0;
}

/// Normalise a user-supplied member role. Returns the empty string when
/// the value is not one of `owner` / `admin` / `member` so the caller
/// can surface a 400.
pub fn normalizeMemberRole(role: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, role, &std.ascii.whitespace);
    if (trimmed.len == 0) return "member";
    if (std.mem.eql(u8, trimmed, "owner")) return "owner";
    if (std.mem.eql(u8, trimmed, "admin")) return "admin";
    if (std.mem.eql(u8, trimmed, "member")) return "member";
    return "";
}

/// Slug shape check: lowercase ASCII alphanumerics with non-consecutive
/// `-` separators. Matches the regex `[a-z0-9]+(?:-[a-z0-9]+)*`.
pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0) return false;
    var prev_hyphen = true;
    for (slug) |c| {
        if (c == '-') {
            if (prev_hyphen) return false;
            prev_hyphen = true;
        } else if (std.ascii.isAlphanumeric(c)) {
            prev_hyphen = false;
        } else {
            return false;
        }
    }
    return !prev_hyphen;
}

/// Default 3-letter uppercase `issue_prefix` derived from the first
/// three alphabetic chars of the workspace name. Falls back to `XXX`
/// when the name has fewer than 3 letters.
pub fn defaultIssuePrefix(name: []const u8, out: *[3]u8) []const u8 {
    var i: usize = 0;
    for (name) |c| {
        if (std.ascii.isAlphabetic(c)) {
            out[i] = std.ascii.toUpper(c);
            i += 1;
            if (i == 3) return out[0..3];
        }
    }
    while (i < 3) : (i += 1) out[i] = 'X';
    return out[0..3];
}

/// Parse a `COUNT(*)` cell that comes back as text from `zfinal.DB`.
/// Returns 0 when the cell is NULL or non-numeric.
pub fn parseCount(text: ?[]const u8) i64 {
    const t = text orelse return 0;
    return std.fmt.parseInt(i64, t, 10) catch 0;
}

/// Parse a JSON text blob, returning the value on success and `null`
/// on failure or NULL input. The caller is responsible for the
/// `holder` lifetime because the returned `std.json.Value` references
/// its arena.
pub fn parseJsonValue(allocator: std.mem.Allocator, text: ?[]const u8, holder: *?std.json.Parsed(std.json.Value)) !?std.json.Value {
    const t = text orelse return null;
    if (t.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, t, .{}) catch return null;
    holder.* = parsed;
    return parsed.value;
}

/// Format a Unix-seconds value as an RFC 3339 / ISO-8601 UTC string
/// (`YYYY-MM-DDTHH:MM:SSZ`). Used by the Lark install session insert
/// so the Postgres `timestamptz` column accepts the literal.
pub fn rfc3339(allocator: std.mem.Allocator, ts: i64) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sd = epoch.getDaySeconds();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        sd.getHoursIntoDay(), sd.getMinutesIntoHour(), sd.getSecondsIntoMinute(),
    });
}

// ──────────────────────────────────────────────────────────────────────
// context helpers
// ──────────────────────────────────────────────────────────────────────

/// Return the authenticated user (id + email) stashed on the context
/// by the `AuthInterceptor`. `null` when the request was anonymous
/// or came in via a service-account bypass that does not set `user_id`.
pub fn getCurrentUser(ctx: *zfinal.Context) ?struct { id: []const u8, email: []const u8 } {
    const id = ctx.attributes.get("user_id") orelse return null;
    const email = ctx.attributes.get("email") orelse return null;
    return .{ .id = id, .email = email };
}

/// Pull the workspace id stashed on the context by the workspace
/// middleware. `null` when the middleware did not run (e.g. legacy
/// /api/workspaces routes that read `:id` from the path).
pub fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

/// Pull the user id stashed on the context by the auth middleware.
pub fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

/// Pull the workspace role stashed on the context by the workspace
/// middleware. Empty string when missing.
pub fn getWorkspaceRole(ctx: *zfinal.Context) []const u8 {
    return ctx.attributes.get("workspace_role") orelse "";
}

/// Helper used by handlers that already ran the `RequireWorkspaceRole`
/// middleware — re-checks the role attribute for redundancy and emits
/// the canonical 403 body.
pub fn requireWorkspaceRoleAttr(ctx: *zfinal.Context, min_role: []const u8) !bool {
    const role = ctx.attributes.get("workspace_role") orelse "";
    if (roleRank(role) < roleRank(min_role)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
        return false;
    }
    return true;
}

// ──────────────────────────────────────────────────────────────────────
// in-memory accessors
// ──────────────────────────────────────────────────────────────────────

/// Map an in-memory `WorkspaceEntry` to the API response shape.
pub fn memWorkspaceResponse(entry: WorkspaceEntry) WorkspaceResponse {
    return WorkspaceResponse{
        .id = entry.id,
        .name = entry.name,
        .slug = entry.slug,
        .description = if (entry.description.len > 0) entry.description else null,
        .context = if (entry.context.len > 0) entry.context else null,
        .settings = null,
        .repos = null,
        .issue_prefix = entry.issue_prefix,
        .avatar_url = if (entry.avatar_url.len > 0) entry.avatar_url else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// Look up the member role for `(workspace_id, user_id)` in the
/// in-memory store. `null` when the workspace is unknown or the user
/// is not a member.
pub fn memGetRole(workspace_id: []const u8, user_id: []const u8) ?[]const u8 {
    const members = mem_members orelse return null;
    const list = members.get(workspace_id) orelse return null;
    for (list.items) |m| {
        if (std.mem.eql(u8, m.user_id, user_id)) return m.role;
    }
    return null;
}

/// Count the owners in the in-memory `workspace_id` row. Used by
/// member-management flows that must refuse to demote the last owner.
pub fn memCountOwners(workspace_id: []const u8) usize {
    const members = mem_members orelse return 0;
    const list = members.get(workspace_id) orelse return 0;
    var count: usize = 0;
    for (list.items) |m| {
        if (std.mem.eql(u8, m.role, "owner")) count += 1;
    }
    return count;
}

/// Add a member to the in-memory `mem_members` map. The caller is
/// responsible for taking `mem_mutex` when concurrent access matters;
/// `memAddMember` itself locks for the whole append.
pub fn memAddMember(workspace_id: []const u8, user_id: []const u8, role: []const u8, name: []const u8, email: []const u8) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list = mem_members.?.getPtr(workspace_id) orelse return;
    try list.append(memAlloc(), .{
        .user_id = try memDup(user_id),
        .role = try memDup(role),
        .name = try memDup(name),
        .email = try memDup(email),
    });
}

/// Look up a workspace's display name from the in-memory store.
/// `null` when the store is uninitialised or the workspace is unknown.
/// Used by `src/modules/invitation/service.zig`.
pub fn memGetWorkspaceName(workspace_id: []const u8) ?[]const u8 {
    if (mem_workspaces == null) return null;
    const entry = mem_workspaces.?.get(workspace_id) orelse return null;
    return entry.name;
}

/// In-memory RBAC check used by the fallback path. Sets the 401/403
/// status on the context and returns `false` when the call should
/// short-circuit. Caller must `defer` the unlock.
pub fn memRequireAccess(ctx: *zfinal.Context, workspace_id: []const u8, min_role: []const u8) !bool {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return false;
    };
    const role = memGetRole(workspace_id, u.id) orelse {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "forbidden" });
        return false;
    };
    if (roleRank(role) < roleRank(min_role)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "forbidden" });
        return false;
    }
    return true;
}

// ──────────────────────────────────────────────────────────────────────
// DB accessors
// ──────────────────────────────────────────────────────────────────────

/// Resolve a workspace slug to its id. Uses the database when
/// available, otherwise falls back to the in-memory workspace store.
/// The returned slice is `allocator`-owned and must be freed by the
/// caller. Used by `src/modules/realtime/service.zig`.
pub fn resolveSlug(allocator: std.mem.Allocator, slug: []const u8) ?[]const u8 {
    if (borrowDb()) |db_handle| {
        defer deps.releaseBack(db_handle);
        var res = db_handle.queryParams(
            "SELECT id FROM workspace WHERE slug = $1",
            &[_]SqlParam{.{ .text = slug }},
        ) catch return null;
        defer res.deinit();
        if (res.rows.items.len == 0) return null;
        const id = res.rows.items[0].getText(0) orelse "";
        return allocator.dupe(u8, id) catch null;
    }

    memInit() catch return null;
    mem_mutex.lockUncancelable(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_workspaces) |*map| {
        var it = map.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.slug, slug)) {
                return allocator.dupe(u8, e.key_ptr.*) catch null;
            }
        }
    }
    return null;
}

/// DB-side RBAC check. Returns the caller's role on success; on
/// failure, sets the 401/403 status on the context and returns
/// `null` (the caller should immediately `return`).
pub fn requireAccess(ctx: *zfinal.Context, db_handle: *zfinal.DB, workspace_id: []const u8, min_role: []const u8) !?[]const u8 {
    const u = getCurrentUser(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return null;
    };

    var res = db_handle.queryParams(
        "SELECT role FROM member WHERE workspace_id = $1 AND user_id = $2",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = u.id },
        },
    ) catch |err| {
        std.log.scoped(.workspace_model).err("membership check failed: {}", .{err});
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "database_error" });
        return null;
    };
    defer res.deinit();

    if (res.rows.items.len == 0) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "forbidden" });
        return null;
    }

    const role = res.rows.items[0].getText(0) orelse "";
    if (roleRank(role) < roleRank(min_role)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "forbidden" });
        return null;
    }
    return role;
}

/// Project a `SELECT id::text, name, slug, description, context,
/// settings::text, repos::text, issue_prefix, avatar_url,
/// created_at, updated_at FROM workspace` row to the API
/// response shape. `settings_holder` and `repos_holder` own the parsed
/// `std.json.Value` arenas.
///
/// The `::text` casts are mandatory: the driver requests binary result
/// format, so an uncast `uuid` arrives as 16 raw bytes, `jsonb` as a
/// version byte plus the document, and `timestamptz` as an i64. Reading
/// those with `getText` yields non-UTF-8 garbage that PostgreSQL then
/// rejects with SQLSTATE 22021 when it is fed back in as a text param.
pub fn workspaceResponseFromRow(allocator: std.mem.Allocator, rs: zfinal.ResultSet, row: usize, settings_holder: *?std.json.Parsed(std.json.Value), repos_holder: *?std.json.Parsed(std.json.Value)) !WorkspaceResponse {
    const r = &rs.rows.items[row];
    return WorkspaceResponse{
        .id = r.getText(0) orelse "",
        .name = r.getText(1) orelse "",
        .slug = r.getText(2) orelse "",
        .description = r.getText(3),
        .context = r.getText(4),
        .settings = try parseJsonValue(allocator, r.getText(5), settings_holder),
        .repos = try parseJsonValue(allocator, r.getText(6), repos_holder),
        .issue_prefix = r.getText(7) orelse "",
        .avatar_url = r.getText(8),
        .created_at = r.getText(9) orelse "",
        .updated_at = r.getText(10) orelse "",
    };
}

// ──────────────────────────────────────────────────────────────────────
// cross-module response helpers
// ──────────────────────────────────────────────────────────────────────

/// Map a `GithubInstallationEntry` to the API response shape.
pub fn githubResponseFromEntry(entry: GithubInstallationEntry) GithubInstallationResponse {
    return GithubInstallationResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .installation_id = entry.installation_id,
        .account_login = entry.account_login,
        .account_url = entry.account_url,
        .repository_selection = entry.repository_selection,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// Map a `LarkInstallationEntry` to the API response shape.
pub fn larkResponseFromEntry(entry: LarkInstallationEntry) LarkInstallationResponse {
    return LarkInstallationResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .app_id = entry.app_id,
        .tenant_key = entry.tenant_key,
        .tenant_name = entry.tenant_name,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}
