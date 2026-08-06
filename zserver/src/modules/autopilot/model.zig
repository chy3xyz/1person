//! Autopilot module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape, request/response DTOs) and
//! the escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic and the in-memory autopilot + trigger stores.
//!
//! The `autopilot` and `autopilot_trigger` tables use UUID PKs with
//! JSONB / boolean / TIMESTAMPTZ columns that the ORM can't model
//! cleanly, so all SQL goes through `zfinal.SqlParam` via
//! `deps.acquire()`. The in-memory fallback uses the `AutopilotEntry`
//! and `TriggerEntry` structs defined here so the no-DB smoke-test
//! path stays deterministic.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// Page allocator used by the in-memory store. Matches the
/// per-process lifetime of the autopilot registry.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Parse an optional JSON text column into a `std.json.Value`.
/// Returns `null` for missing/empty/invalid text. The parsed value
/// is allocated with `allocator` (caller-owned; the caller's arena
/// or page allocator handles reclamation).
pub fn jsonValueOrNull(allocator: std.mem.Allocator, text: ?[]const u8) !?std.json.Value {
    const t = text orelse return null;
    if (t.len == 0) return null;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, t, .{}) catch null;
}

/// Allocate a copy of `text` using the in-memory allocator.
pub fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

/// Seconds-since-epoch formatted as a decimal string. Used for the
/// in-memory fallback row's `created_at` / `updated_at` columns.
pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

/// Stable pseudo-UUID for the in-memory store.
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

// ──────────────────────────────────────────────────────────────────────
// in-memory row shapes
// ──────────────────────────────────────────────────────────────────────

/// In-memory `autopilot` row.
pub const AutopilotEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: []const u8,
    project_id: []const u8,
    assignee_type: []const u8,
    assignee_id: []const u8,
    status: []const u8,
    execution_mode: []const u8,
    issue_title_template: []const u8,
    created_by_type: []const u8,
    created_by_id: []const u8,
    last_run_at: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `autopilot_trigger` row.
pub const TriggerEntry = struct {
    id: []const u8,
    autopilot_id: []const u8,
    kind: []const u8,
    enabled: bool,
    cron_expression: []const u8,
    timezone: []const u8,
    next_run_at: []const u8,
    webhook_token: []const u8,
    label: []const u8,
    last_fired_at: []const u8,
    provider: []const u8,
    signing_secret: []const u8,
    event_filters: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// In-memory `webhook_delivery` row. Captures the request/response
/// of every webhook trigger invocation so operators can inspect
/// failures and replay them.
pub const WebhookDeliveryEntry = struct {
    id: []const u8,
    autopilot_id: []const u8,
    trigger_id: []const u8,
    event_type: []const u8,
    payload: []const u8,
    response_status: i32,
    response_body: []const u8,
    created_at: []const u8,
};

/// Wire DTO for `GET /api/autopilots/:id/deliveries` and the
/// `/deliveries/:deliveryId` single-item fetch.
pub const WebhookDeliveryResponse = struct {
    id: []const u8,
    autopilot_id: []const u8,
    trigger_id: []const u8,
    event_type: []const u8,
    payload: []const u8,
    response_status: i32,
    response_body: []const u8,
    created_at: []const u8,
};

pub fn webhookDeliveryResponseFromEntry(entry: WebhookDeliveryEntry) WebhookDeliveryResponse {
    return .{
        .id = entry.id,
        .autopilot_id = entry.autopilot_id,
        .trigger_id = entry.trigger_id,
        .event_type = entry.event_type,
        .payload = entry.payload,
        .response_status = entry.response_status,
        .response_body = entry.response_body,
        .created_at = entry.created_at,
    };
}

/// `POST /:id/triggers/:tid/rotate-webhook-token` response.
pub const RotateWebhookTokenResponse = struct {
    trigger_id: []const u8,
    webhook_token: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// public response DTOs
// ──────────────────────────────────────────────────────────────────────

pub const AutopilotResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    project_id: ?[]const u8,
    assignee_type: []const u8,
    assignee_id: []const u8,
    status: []const u8,
    execution_mode: []const u8,
    issue_title_template: ?[]const u8,
    created_by_type: []const u8,
    created_by_id: []const u8,
    last_run_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const WebhookEventFilter = struct {
    event: []const u8,
    actions: ?[]const []const u8 = null,
};

pub const AutopilotTriggerResponse = struct {
    id: []const u8,
    autopilot_id: []const u8,
    kind: []const u8,
    enabled: bool,
    cron_expression: ?[]const u8,
    timezone: ?[]const u8,
    next_run_at: ?[]const u8,
    webhook_token: ?[]const u8,
    webhook_path: ?[]const u8,
    webhook_url: ?[]const u8,
    provider: ?[]const u8,
    has_signing_secret: bool,
    signing_secret_hint: ?[]const u8,
    label: ?[]const u8,
    last_fired_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    event_filters: ?[]WebhookEventFilter,
};

pub const AutopilotRunResponse = struct {
    id: []const u8,
    autopilot_id: []const u8,
    trigger_id: ?[]const u8,
    source: []const u8,
    status: []const u8,
    issue_id: ?[]const u8,
    task_id: ?[]const u8,
    triggered_at: []const u8,
    completed_at: ?[]const u8,
    failure_reason: ?[]const u8,
    trigger_payload: ?std.json.Value,
    result: ?std.json.Value,
    created_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

pub const CreateAutopilotRequest = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    assignee_id: []const u8,
    execution_mode: []const u8,
    issue_title_template: ?[]const u8 = null,
};

pub const UpdateAutopilotRequest = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    execution_mode: ?[]const u8 = null,
    issue_title_template: ?[]const u8 = null,
};

pub const CreateTriggerRequest = struct {
    kind: []const u8,
    cron_expression: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    label: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    event_filters: ?[]WebhookEventFilter = null,
};

pub const UpdateTriggerRequest = struct {
    enabled: ?bool = null,
    cron_expression: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    label: ?[]const u8 = null,
    event_filters: ?[]WebhookEventFilter = null,
};

pub const SetSigningSecretRequest = struct {
    signing_secret: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// response builders
// ──────────────────────────────────────────────────────────────────────

pub fn autopilotResponseFromEntry(entry: AutopilotEntry) AutopilotResponse {
    return AutopilotResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .title = entry.title,
        .description = if (entry.description.len > 0) entry.description else null,
        .project_id = if (entry.project_id.len > 0) entry.project_id else null,
        .assignee_type = entry.assignee_type,
        .assignee_id = entry.assignee_id,
        .status = entry.status,
        .execution_mode = entry.execution_mode,
        .issue_title_template = if (entry.issue_title_template.len > 0) entry.issue_title_template else null,
        .created_by_type = entry.created_by_type,
        .created_by_id = entry.created_by_id,
        .last_run_at = if (entry.last_run_at.len > 0) entry.last_run_at else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

pub fn autopilotResponseFromRow(rs: *zfinal.ResultSet, row: usize) AutopilotResponse {
    const r = &rs.rows.items[row];
    return AutopilotResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .title = r.getText(2) orelse "",
        .description = r.getText(3),
        .project_id = r.getText(4),
        .assignee_type = r.getText(5) orelse "agent",
        .assignee_id = r.getText(6) orelse "",
        .status = r.getText(7) orelse "active",
        .execution_mode = r.getText(8) orelse "create_issue",
        .issue_title_template = r.getText(9),
        .created_by_type = r.getText(10) orelse "member",
        .created_by_id = r.getText(11) orelse "",
        .last_run_at = r.getText(12),
        .created_at = r.getText(13) orelse "",
        .updated_at = r.getText(14) orelse "",
    };
}

pub fn autopilotEntryFromRow(rs: *zfinal.ResultSet, row: usize) AutopilotEntry {
    const r = &rs.rows.items[row];
    return AutopilotEntry{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .title = r.getText(2) orelse "",
        .description = r.getText(3) orelse "",
        .project_id = r.getText(4) orelse "",
        .assignee_type = r.getText(5) orelse "agent",
        .assignee_id = r.getText(6) orelse "",
        .status = r.getText(7) orelse "active",
        .execution_mode = r.getText(8) orelse "create_issue",
        .issue_title_template = r.getText(9) orelse "",
        .created_by_type = r.getText(10) orelse "member",
        .created_by_id = r.getText(11) orelse "",
        .last_run_at = r.getText(12) orelse "",
        .created_at = r.getText(13) orelse "",
        .updated_at = r.getText(14) orelse "",
    };
}

pub fn triggerEntryFromRow(rs: *zfinal.ResultSet, row: usize) TriggerEntry {
    const r = &rs.rows.items[row];
    const enabled_text = r.getText(3) orelse "true";
    return TriggerEntry{
        .id = r.getText(0) orelse "",
        .autopilot_id = r.getText(1) orelse "",
        .kind = r.getText(2) orelse "",
        .enabled = std.mem.eql(u8, enabled_text, "t") or std.mem.eql(u8, enabled_text, "true") or std.mem.eql(u8, enabled_text, "1"),
        .cron_expression = r.getText(4) orelse "",
        .timezone = r.getText(5) orelse "",
        .next_run_at = r.getText(6) orelse "",
        .webhook_token = r.getText(7) orelse "",
        .label = r.getText(8) orelse "",
        .last_fired_at = r.getText(9) orelse "",
        .provider = r.getText(10) orelse "",
        .signing_secret = r.getText(11) orelse "",
        .event_filters = r.getText(12) orelse "",
        .created_at = r.getText(13) orelse "",
        .updated_at = r.getText(14) orelse "",
    };
}

pub fn triggerResponseFromEntry(allocator: std.mem.Allocator, cfg: *const Config, entry: TriggerEntry) !AutopilotTriggerResponse {
    var filters_holder: ?std.json.Parsed([]WebhookEventFilter) = null;
    defer if (filters_holder) |p| p.deinit();
    const event_filters = if (entry.event_filters.len > 0) try parseEventFilters(allocator, entry.event_filters, &filters_holder) else null;

    const webhook_path = if (entry.webhook_token.len > 0 and std.mem.eql(u8, entry.kind, "webhook"))
        try std.fmt.allocPrint(allocator, "/api/webhooks/autopilots/{s}", .{entry.webhook_token})
    else
        null;
    const webhook_url = if (webhook_path != null and cfg.public_url.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.public_url, webhook_path.? })
    else
        null;

    const provider = if (entry.provider.len > 0) entry.provider else if (std.mem.eql(u8, entry.kind, "webhook")) @as([]const u8, "generic") else null;
    const has_secret = entry.signing_secret.len > 0;
    const hint = if (has_secret and entry.signing_secret.len >= 4) entry.signing_secret[entry.signing_secret.len - 4 ..] else null;

    return AutopilotTriggerResponse{
        .id = entry.id,
        .autopilot_id = entry.autopilot_id,
        .kind = entry.kind,
        .enabled = entry.enabled,
        .cron_expression = if (entry.cron_expression.len > 0) entry.cron_expression else null,
        .timezone = if (entry.timezone.len > 0) entry.timezone else null,
        .next_run_at = if (entry.next_run_at.len > 0) entry.next_run_at else null,
        .webhook_token = if (entry.webhook_token.len > 0) entry.webhook_token else null,
        .webhook_path = webhook_path,
        .webhook_url = webhook_url,
        .provider = provider,
        .has_signing_secret = has_secret,
        .signing_secret_hint = hint,
        .label = if (entry.label.len > 0) entry.label else null,
        .last_fired_at = if (entry.last_fired_at.len > 0) entry.last_fired_at else null,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .event_filters = event_filters,
    };
}

pub fn triggerResponseFromRow(allocator: std.mem.Allocator, cfg: *const Config, rs: *zfinal.ResultSet, row: usize) !AutopilotTriggerResponse {
    const r = &rs.rows.items[row];
    const enabled_text = r.getText(3) orelse "true";
    const entry = TriggerEntry{
        .id = r.getText(0) orelse "",
        .autopilot_id = r.getText(1) orelse "",
        .kind = r.getText(2) orelse "",
        .enabled = std.mem.eql(u8, enabled_text, "t") or std.mem.eql(u8, enabled_text, "true") or std.mem.eql(u8, enabled_text, "1"),
        .cron_expression = r.getText(4) orelse "",
        .timezone = r.getText(5) orelse "",
        .next_run_at = r.getText(6) orelse "",
        .webhook_token = r.getText(7) orelse "",
        .label = r.getText(8) orelse "",
        .last_fired_at = r.getText(9) orelse "",
        .provider = r.getText(10) orelse "",
        .signing_secret = r.getText(11) orelse "",
        .event_filters = r.getText(12) orelse "",
        .created_at = r.getText(13) orelse "",
        .updated_at = r.getText(14) orelse "",
    };
    return try triggerResponseFromEntry(allocator, cfg, entry);
}

// ──────────────────────────────────────────────────────────────────────
// escape-hatch SQL helpers
// ──────────────────────────────────────────────────────────────────────

/// Verify the `assignee` (agent or squad) belongs to the workspace
/// and is not archived. Returns `true` for valid, `false` otherwise.
pub fn validateAssignee(db: *zfinal.DB, workspace_id: []const u8, assignee_type: []const u8, assignee_id: []const u8) !bool {
    if (std.mem.eql(u8, assignee_type, "agent")) {
        var rs = try db.queryParams(
            "SELECT 1 FROM agent WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL",
            &[_]SqlParam{ .{ .text = assignee_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        return rs.rows.items.len > 0;
    } else if (std.mem.eql(u8, assignee_type, "squad")) {
        var rs = try db.queryParams(
            "SELECT 1 FROM squad WHERE id = $1::uuid AND workspace_id = $2::uuid AND archived_at IS NULL",
            &[_]SqlParam{ .{ .text = assignee_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        return rs.rows.items.len > 0;
    }
    return false;
}

/// `SELECT id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at,
/// webhook_token, label, last_fired_at, provider, signing_secret, event_filters,
/// created_at, updated_at FROM autopilot_trigger WHERE autopilot_id = $1::uuid
/// ORDER BY created_at ASC` — used by `getAutopilot` and `listTriggers`.
pub fn dbTriggersForAutopilot(allocator: std.mem.Allocator, db: *zfinal.DB, g_cfg: *const Config, autopilot_id: []const u8) ![]AutopilotTriggerResponse {
    var rs = try db.queryParams(
        "SELECT id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at " ++
            "FROM autopilot_trigger WHERE autopilot_id = $1::uuid ORDER BY created_at ASC",
        &[_]SqlParam{.{ .text = autopilot_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(AutopilotTriggerResponse) = .empty;
    defer list.deinit(allocator);
    for (0..rs.rows.items.len) |i| {
        try list.append(allocator, try triggerResponseFromRow(allocator, g_cfg, &rs, i));
    }
    return try list.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────
// shared helpers
// ──────────────────────────────────────────────────────────────────────

pub fn emptyJsonObject(_allocator: std.mem.Allocator) std.json.Value {
    _ = _allocator;
    return .{ .object = std.json.ObjectMap.empty };
}

pub fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8, holder: *?std.json.Parsed(std.json.Value)) !std.json.Value {
    if (text.len == 0) return emptyJsonObject(allocator);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return emptyJsonObject(allocator);
    holder.* = parsed;
    return parsed.value;
}

pub fn parseEventFilters(allocator: std.mem.Allocator, text: []const u8, holder: *?std.json.Parsed([]WebhookEventFilter)) ![]WebhookEventFilter {
    if (text.len == 0) return &[_]WebhookEventFilter{};
    const parsed = std.json.parseFromSlice([]WebhookEventFilter, allocator, text, .{}) catch return &[_]WebhookEventFilter{};
    holder.* = parsed;
    return parsed.value;
}

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

pub fn isValidStatus(s: []const u8) bool {
    const valid = [_][]const u8{ "active", "paused", "archived" };
    for (valid) |v| if (std.mem.eql(u8, s, v)) return true;
    return false;
}

pub fn isValidExecutionMode(m: []const u8) bool {
    return std.mem.eql(u8, m, "create_issue") or std.mem.eql(u8, m, "run_only");
}

pub fn isValidAssigneeType(t: []const u8) bool {
    return std.mem.eql(u8, t, "agent") or std.mem.eql(u8, t, "squad");
}

pub fn isValidTriggerKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "schedule") or std.mem.eql(u8, k, "webhook");
}

pub fn isValidProvider(p: []const u8) bool {
    return std.mem.eql(u8, p, "generic") or std.mem.eql(u8, p, "github");
}

pub fn stringOrEmpty(s: ?[]const u8) []const u8 {
    return s orelse "";
}
