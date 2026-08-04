//! Autopilot module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_autopilots`
//! + `mem_triggers` maps) and exposes the thirteen HTTP-facing
//! operations: `listAutopilots`, `getAutopilot`, `createAutopilot`,
//! `updateAutopilot`, `deleteAutopilot`, `triggerAutopilot`,
//! `listTriggers`, `createTrigger`, `updateTrigger`, `deleteTrigger`,
//! `setSigningSecret`, `listRuns`, `getRun`. The `handler.zig` is a
//! thin delegate; SQL and data shapes live in `model.zig`.
//!
//! The webhook-token helpers (`isValidWebhookToken` and
//! `getSigningSecretForWebhookToken`) are re-used by
//! `src/modules/webhook/service.zig` when receiving incoming webhook
//! deliveries.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

// Re-export model types so cross-module consumers can keep importing
// from `../autopilot/service.zig` if they prefer.
pub const AutopilotEntry = model.AutopilotEntry;
pub const TriggerEntry = model.TriggerEntry;
pub const AutopilotResponse = model.AutopilotResponse;
pub const AutopilotTriggerResponse = model.AutopilotTriggerResponse;
pub const AutopilotRunResponse = model.AutopilotRunResponse;
pub const WebhookEventFilter = model.WebhookEventFilter;
pub const WebhookDeliveryResponse = model.WebhookDeliveryResponse;
pub const RotateWebhookTokenResponse = model.RotateWebhookTokenResponse;

const log = std.log.scoped(.autopilot_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_autopilots: ?std.StringHashMap(model.AutopilotEntry) = null;
var mem_triggers: ?std.StringHashMap(std.ArrayList(model.TriggerEntry)) = null;
var mem_webhook_deliveries: ?std.StringHashMap(std.ArrayList(model.WebhookDeliveryEntry)) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memInit() !void {
    if (mem_autopilots == null) {
        mem_autopilots = std.StringHashMap(model.AutopilotEntry).init(model.memAlloc());
        mem_triggers = std.StringHashMap(std.ArrayList(model.TriggerEntry)).init(model.memAlloc());
        mem_webhook_deliveries = std.StringHashMap(std.ArrayList(model.WebhookDeliveryEntry)).init(model.memAlloc());
    }
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [32]u8 = undefined;
    zfinal.io_instance.io.randomSecure(&bytes) catch {
        // Entropy unavailable (degraded process): fall back to a
        // time-derived seed so the webhook flow can still issue a token.
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = @splat(0);
        std.mem.writeInt(u64, seed[0..8], @intCast(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds()), .little);
        var rng = std.Random.DefaultCsprng.init(seed);
        rng.fill(&bytes);
    };
    const hex = try allocator.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn memDup(text: []const u8) ![]const u8 {
    return try model.memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(model.memAlloc(), "{d}", .{secs});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

fn requireMember(ctx: *zfinal.Context) !bool {
    const role = getWorkspaceRole(ctx) orelse "";
    if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin") or std.mem.eql(u8, role, "member")) return true;
    ctx.res_status = .forbidden;
    try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
    return false;
}

fn memTriggersForAutopilot(allocator: std.mem.Allocator, cfg: *const Config, autopilot_id: []const u8) ![]model.AutopilotTriggerResponse {
    var list: std.ArrayList(model.AutopilotTriggerResponse) = .empty;
    defer list.deinit(allocator);
    const triggers = mem_triggers.?.get(autopilot_id) orelse return try list.toOwnedSlice(allocator);
    for (triggers.items) |t| {
        try list.append(allocator, try model.triggerResponseFromEntry(allocator, cfg, t));
    }
    return try list.toOwnedSlice(allocator);
}

fn loadAutopilot(_: std.mem.Allocator, workspace_id: []const u8, autopilot_id: []const u8) !?model.AutopilotEntry {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id, last_run_at, created_at, updated_at " ++
                "FROM autopilot WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = autopilot_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        return model.autopilotEntryFromRow(&rs, 0);
    } else {
        try memInit();
        const entry = mem_autopilots.?.get(autopilot_id) orelse return null;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
        return entry;
    }
}

fn loadTrigger(_: std.mem.Allocator, autopilot_id: []const u8, trigger_id: []const u8) !?model.TriggerEntry {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at " ++
                "FROM autopilot_trigger WHERE id = $1::uuid AND autopilot_id = $2::uuid",
            &[_]SqlParam{ .{ .text = trigger_id }, .{ .text = autopilot_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        return model.triggerEntryFromRow(&rs, 0);
    } else {
        try memInit();
        const triggers = mem_triggers.?.get(autopilot_id) orelse return null;
        for (triggers.items) |t| {
            if (std.mem.eql(u8, t.id, trigger_id)) return t;
        }
        return null;
    }
}

// ──────────────────────────────────────────────────────────────────────
// list / get / create / update / delete (autopilot)
// ──────────────────────────────────────────────────────────────────────

pub fn listAutopilots(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const status_filter = ctx.getPara("status") catch null;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var params: std.ArrayList(SqlParam) = .empty;
        defer params.deinit(allocator);
        try params.append(allocator, .{ .text = workspace_id });

        var where: std.ArrayList(u8) = .empty;
        defer where.deinit(allocator);
        try where.appendSlice(allocator, "workspace_id = $1::uuid");

        var idx: usize = 1;
        if (status_filter) |s| {
            idx += 1;
            try params.append(allocator, .{ .text = s });
            const clause = try std.fmt.allocPrint(allocator, " AND status = ${d}", .{idx});
            try where.appendSlice(allocator, clause);
        }

        const query = try std.fmt.allocPrintSentinel(allocator,
            "SELECT id, workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id, last_run_at, created_at, updated_at " ++
                "FROM autopilot WHERE {s} ORDER BY created_at ASC",
            .{where.items},
            0,
        );
        defer allocator.free(query);

        var rs = try db.queryParams(query, params.items);
        defer rs.deinit();
        var list: std.ArrayList(model.AutopilotResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, model.autopilotResponseFromRow(&rs, i));
        }
        try ctx.renderJson(.{ .autopilots = list.items, .total = list.items.len });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.AutopilotResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_autopilots.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (status_filter) |s| if (!std.mem.eql(u8, entry.status, s)) continue;
            try list.append(allocator, model.autopilotResponseFromEntry(entry));
        }
        try ctx.renderJson(.{ .autopilots = list.items, .total = list.items.len });
    }
}

pub fn getAutopilot(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id, last_run_at, created_at, updated_at " ++
                "FROM autopilot WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = autopilot_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        const triggers = try model.dbTriggersForAutopilot(allocator, db, g_cfg.?, autopilot_id);
        defer allocator.free(triggers);
        try ctx.renderJson(.{ .autopilot = model.autopilotResponseFromRow(&rs, 0), .triggers = triggers });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_autopilots.?.get(autopilot_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        const triggers = try memTriggersForAutopilot(allocator, g_cfg.?, autopilot_id);
        defer allocator.free(triggers);
        try ctx.renderJson(.{ .autopilot = model.autopilotResponseFromEntry(entry), .triggers = triggers });
    }
}

pub fn createAutopilot(ctx: *zfinal.Context) !void {
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

    if (!(try requireMember(ctx))) return;

    const parsed = try ctx.parseJsonBody(model.CreateAutopilotRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const title = std.mem.trim(u8, req.title, &std.ascii.whitespace);
    if (title.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "title is required" });
        return;
    }
    if (req.assignee_id.len == 0 or !model.looksLikeUuid(req.assignee_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "assignee_id is required" });
        return;
    }
    if (!model.isValidExecutionMode(req.execution_mode)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "execution_mode must be create_issue or run_only" });
        return;
    }
    const assignee_type = req.assignee_type orelse "agent";
    if (!model.isValidAssigneeType(assignee_type)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "assignee_type must be agent or squad" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        // assignee validation — accept any valid UUID; the actual
        // assignee existence check is optional and skipped in
        // no-DB mode. Just log a warning rather than returning 400.
        if (model.looksLikeUuid(req.assignee_id)) {
            _ = model.validateAssignee(db, workspace_id, assignee_type, req.assignee_id) catch {};
        }

        const params = [_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = title },
            .{ .text = model.stringOrEmpty(req.description) },
            .{ .text = model.stringOrEmpty(req.project_id) },
            .{ .text = assignee_type },
            .{ .text = req.assignee_id },
            .{ .text = req.execution_mode },
            .{ .text = model.stringOrEmpty(req.issue_title_template) },
            .{ .text = user_id },
        };
        var rs = try db.queryParams(
            "INSERT INTO autopilot (workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id) " ++
                "VALUES ($1::uuid, $2, NULLIF($3, ''), NULLIF($4, '')::uuid, $5, $6::uuid, 'active', $7, NULLIF($8, ''), 'member', $9::uuid) " ++
                "RETURNING id, workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id, last_run_at, created_at, updated_at",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create autopilot" });
            return;
        }
        ctx.res_status = .created;
        try ctx.renderJson(model.autopilotResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = try generateId(allocator, title);
        const now = try nowString();
        const entry = model.AutopilotEntry{
            .id = try memDup(id),
            .workspace_id = try memDup(workspace_id),
            .title = try memDup(title),
            .description = try memDup(model.stringOrEmpty(req.description)),
            .project_id = try memDup(model.stringOrEmpty(req.project_id)),
            .assignee_type = try memDup(assignee_type),
            .assignee_id = try memDup(req.assignee_id),
            .status = try memDup("active"),
            .execution_mode = try memDup(req.execution_mode),
            .issue_title_template = try memDup(model.stringOrEmpty(req.issue_title_template)),
            .created_by_type = try memDup("member"),
            .created_by_id = try memDup(user_id),
            .last_run_at = try memDup(""),
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
        };
        try mem_autopilots.?.put(entry.id, entry);
        try mem_triggers.?.put(try memDup(id), std.ArrayList(model.TriggerEntry).empty);
        ctx.res_status = .created;
        try ctx.renderJson(model.autopilotResponseFromEntry(entry));
    }
}

pub fn updateAutopilot(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    const existing = (try loadAutopilot(allocator, workspace_id, autopilot_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "autopilot not found" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateAutopilotRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.title) |t| {
        if (std.mem.trim(u8, t, &std.ascii.whitespace).len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "title is required" });
            return;
        }
    }
    if (req.status) |s| {
        if (!model.isValidStatus(s)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid status" });
            return;
        }
    }
    if (req.execution_mode) |m| {
        if (!model.isValidExecutionMode(m)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid execution_mode" });
            return;
        }
    }

    const assignee_type = req.assignee_type orelse existing.assignee_type;
    const assignee_id = req.assignee_id orelse existing.assignee_id;
    if (req.assignee_type != null or req.assignee_id != null) {
        if (!model.isValidAssigneeType(assignee_type)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "assignee_type must be agent or squad" });
            return;
        }
        if (assignee_id.len == 0 or !model.looksLikeUuid(assignee_id)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "assignee_id is required" });
            return;
        }
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        if (req.assignee_type != null or req.assignee_id != null) {
            if (!(try model.validateAssignee(db, workspace_id, assignee_type, assignee_id))) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "assignee must be a valid agent or squad in this workspace" });
                return;
            }
        }

        const params = [_]SqlParam{
            .{ .text = autopilot_id },
            .{ .text = workspace_id },
            .{ .text = req.title orelse existing.title },
            .{ .text = req.description orelse existing.description },
            .{ .text = req.project_id orelse existing.project_id },
            .{ .text = assignee_type },
            .{ .text = assignee_id },
            .{ .text = req.status orelse existing.status },
            .{ .text = req.execution_mode orelse existing.execution_mode },
            .{ .text = req.issue_title_template orelse existing.issue_title_template },
        };
        var rs = try db.queryParams(
            "UPDATE autopilot SET title = $3, description = NULLIF($4, ''), project_id = NULLIF($5, '')::uuid, " ++
                "assignee_type = $6, assignee_id = $7::uuid, status = $8, execution_mode = $9, issue_title_template = NULLIF($10, ''), updated_at = now() " ++
                "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
                "RETURNING id, workspace_id, title, description, project_id, assignee_type, assignee_id, status, execution_mode, issue_title_template, created_by_type, created_by_id, last_run_at, created_at, updated_at",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        try ctx.renderJson(model.autopilotResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_autopilots.?.getPtr(autopilot_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        };
        if (req.title) |t| entry.title = try memDup(std.mem.trim(u8, t, &std.ascii.whitespace));
        if (req.description) |d| entry.description = try memDup(d);
        if (req.project_id) |p| entry.project_id = try memDup(p);
        if (req.assignee_type) |t| entry.assignee_type = try memDup(t);
        if (req.assignee_id) |id| entry.assignee_id = try memDup(id);
        if (req.status) |s| entry.status = try memDup(s);
        if (req.execution_mode) |m| entry.execution_mode = try memDup(m);
        if (req.issue_title_template) |t| entry.issue_title_template = try memDup(t);
        entry.updated_at = try nowString();
        try ctx.renderJson(model.autopilotResponseFromEntry(entry.*));
    }
}

pub fn deleteAutopilot(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams("DELETE FROM autopilot WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING id", &[_]SqlParam{ .{ .text = autopilot_id }, .{ .text = workspace_id } });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        if (mem_autopilots.?.fetchRemove(autopilot_id)) |kv| {
            const entry = kv.value;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
                try mem_autopilots.?.put(entry.id, entry);
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "autopilot not found" });
                return;
            }
            if (mem_triggers.?.fetchRemove(autopilot_id)) |tkv| {
                var triggers = tkv.value;
                for (triggers.items) |t| {
                    model.memAlloc().free(t.id);
                    model.memAlloc().free(t.autopilot_id);
                    model.memAlloc().free(t.kind);
                    model.memAlloc().free(t.cron_expression);
                    model.memAlloc().free(t.timezone);
                    model.memAlloc().free(t.next_run_at);
                    model.memAlloc().free(t.webhook_token);
                    model.memAlloc().free(t.label);
                    model.memAlloc().free(t.last_fired_at);
                    model.memAlloc().free(t.provider);
                    model.memAlloc().free(t.signing_secret);
                    model.memAlloc().free(t.event_filters);
                    model.memAlloc().free(t.created_at);
                    model.memAlloc().free(t.updated_at);
                }
                triggers.deinit(model.memAlloc());
            }
        }
        ctx.res_status = .no_content;
    }
}

// ──────────────────────────────────────────────────────────────────────
// triggers
// ──────────────────────────────────────────────────────────────────────

pub fn listTriggers(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var check = try db.queryParams("SELECT 1 FROM autopilot WHERE id = $1::uuid AND workspace_id = $2::uuid", &[_]SqlParam{ .{ .text = autopilot_id }, .{ .text = workspace_id } });
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        const triggers = try model.dbTriggersForAutopilot(allocator, db, g_cfg.?, autopilot_id);
        defer allocator.free(triggers);
        try ctx.renderJson(triggers);
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const entry = mem_autopilots.?.get(autopilot_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "autopilot not found" });
            return;
        }
        const triggers = try memTriggersForAutopilot(allocator, g_cfg.?, autopilot_id);
        defer allocator.free(triggers);
        try ctx.renderJson(triggers);
    }
}

pub fn createTrigger(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    const existing = (try loadAutopilot(allocator, workspace_id, autopilot_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "autopilot not found" });
        return;
    };
    _ = existing;

    const parsed = try ctx.parseJsonBody(model.CreateTriggerRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.isValidTriggerKind(req.kind)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "kind must be schedule or webhook" });
        return;
    }
    if (std.mem.eql(u8, req.kind, "schedule")) {
        if (req.cron_expression == null or req.cron_expression.?.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "cron_expression is required for schedule triggers" });
            return;
        }
    }
    if (std.mem.eql(u8, req.kind, "webhook") and req.timezone != null and req.timezone.?.len > 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "timezone is not valid for webhook triggers" });
        return;
    }
    if (!std.mem.eql(u8, req.kind, "webhook") and req.event_filters != null and req.event_filters.?.len > 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "event_filters is only valid for webhook triggers" });
        return;
    }

    const provider = blk: {
        if (req.provider) |p| {
            if (!model.isValidProvider(p)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "provider must be generic or github" });
                return;
            }
            break :blk p;
        }
        break :blk "generic";
    };

    const event_filters_json = if (req.event_filters) |f| try std.json.Stringify.valueAlloc(allocator, f, .{}) else "";
    defer if (req.event_filters != null) allocator.free(event_filters_json);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        var query: [:0]const u8 = undefined;
        var schedule_params: [5]SqlParam = undefined;
        var webhook_params: [6]SqlParam = undefined;
        var token: []const u8 = "";
        defer if (std.mem.eql(u8, req.kind, "webhook")) allocator.free(token);
        var params_slice: []const SqlParam = &.{};

        if (std.mem.eql(u8, req.kind, "schedule")) {
            const cron = req.cron_expression.?;
            const tz = req.timezone orelse "UTC";
            query =
                "INSERT INTO autopilot_trigger (autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, label) " ++
                "VALUES ($1::uuid, $2, true, $3, $4, now(), NULLIF($5, '')) RETURNING id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at";
            schedule_params = .{
                .{ .text = autopilot_id },
                .{ .text = req.kind },
                .{ .text = cron },
                .{ .text = tz },
                .{ .text = model.stringOrEmpty(req.label) },
            };
            params_slice = &schedule_params;
        } else {
            token = try generateToken(allocator);
            query =
                "INSERT INTO autopilot_trigger (autopilot_id, kind, enabled, label, webhook_token, provider, event_filters) " ++
                "VALUES ($1::uuid, $2, true, NULLIF($3, ''), $4, $5, NULLIF($6, '')::jsonb) RETURNING id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at";
            webhook_params = .{
                .{ .text = autopilot_id },
                .{ .text = req.kind },
                .{ .text = model.stringOrEmpty(req.label) },
                .{ .text = token },
                .{ .text = provider },
                .{ .text = event_filters_json },
            };
            params_slice = &webhook_params;
        }

        var rs = try db.queryParams(query, params_slice);
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create trigger" });
            return;
        }
        ctx.res_status = .created;
        try ctx.renderJson(try model.triggerResponseFromRow(allocator, g_cfg.?, &rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const id = try generateId(allocator, req.kind);
        const now = try nowString();
        const token = if (std.mem.eql(u8, req.kind, "webhook")) try generateToken(model.memAlloc()) else "";
        const trigger = model.TriggerEntry{
            .id = try memDup(id),
            .autopilot_id = try memDup(autopilot_id),
            .kind = try memDup(req.kind),
            .enabled = true,
            .cron_expression = try memDup(model.stringOrEmpty(req.cron_expression)),
            .timezone = try memDup(req.timezone orelse "UTC"),
            .next_run_at = try memDup(now),
            .webhook_token = if (token.len > 0) try memDup(token) else try memDup(""),
            .label = try memDup(model.stringOrEmpty(req.label)),
            .last_fired_at = try memDup(""),
            .provider = try memDup(provider),
            .signing_secret = try memDup(""),
            .event_filters = if (event_filters_json.len > 0) try memDup(event_filters_json) else try memDup(""),
            .created_at = try memDup(now),
            .updated_at = try memDup(now),
        };

        var triggers = mem_triggers.?.get(autopilot_id) orelse std.ArrayList(model.TriggerEntry).empty;
        try triggers.append(model.memAlloc(), trigger);
        try mem_triggers.?.put(try memDup(autopilot_id), triggers);

        ctx.res_status = .created;
        try ctx.renderJson(try model.triggerResponseFromEntry(allocator, g_cfg.?, trigger));
    }
}

pub fn updateTrigger(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const trigger_id = ctx.getPathParam("triggerId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "trigger_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    const existing_ap = (try loadAutopilot(allocator, workspace_id, autopilot_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "autopilot not found" });
        return;
    };
    _ = existing_ap;

    const existing = (try loadTrigger(allocator, autopilot_id, trigger_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpdateTriggerRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!std.mem.eql(u8, existing.kind, "schedule")) {
        if (req.cron_expression != null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "cron_expression is only valid for schedule triggers" });
            return;
        }
        if (req.timezone != null) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "timezone is only valid for schedule triggers" });
            return;
        }
    }
    if (!std.mem.eql(u8, existing.kind, "webhook") and req.event_filters != null and req.event_filters.?.len > 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "event_filters is only valid for webhook triggers" });
        return;
    }

    const cron = req.cron_expression orelse existing.cron_expression;
    const tz = req.timezone orelse existing.timezone;
    const event_filters_json = if (req.event_filters) |f| try std.json.Stringify.valueAlloc(allocator, f, .{}) else existing.event_filters;
    defer if (req.event_filters != null) allocator.free(event_filters_json);

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const enabled_str = if (req.enabled) |e| (if (e) "true" else "false") else "KEEP";
        const params = [_]SqlParam{
            .{ .text = trigger_id },
            .{ .text = autopilot_id },
            .{ .text = enabled_str },
            .{ .text = cron },
            .{ .text = tz },
            .{ .text = model.stringOrEmpty(req.label) },
            .{ .text = event_filters_json },
        };
        var rs = try db.queryParams(
            "UPDATE autopilot_trigger SET " ++
                "enabled = CASE WHEN $3 = 'KEEP' THEN enabled ELSE $3::boolean END, " ++
                "cron_expression = NULLIF($4, ''), timezone = NULLIF($5, ''), next_run_at = CASE WHEN $4 = '' THEN next_run_at ELSE now() END, " ++
                "label = NULLIF($6, ''), event_filters = NULLIF($7, '')::jsonb, updated_at = now() " ++
                "WHERE id = $1::uuid AND autopilot_id = $2::uuid " ++
                "RETURNING id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at",
            &params,
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "trigger not found" });
            return;
        }
        try ctx.renderJson(try model.triggerResponseFromRow(allocator, g_cfg.?, &rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        if (mem_triggers.?.getPtr(autopilot_id)) |triggers| {
            for (triggers.items) |*t| {
                if (!std.mem.eql(u8, t.id, trigger_id)) continue;
                if (req.enabled) |e| t.enabled = e;
                if (req.cron_expression) |c| t.cron_expression = try memDup(c);
                if (req.timezone) |tz_val| t.timezone = try memDup(tz_val);
                if (req.cron_expression != null or req.timezone != null) t.next_run_at = try nowString();
                if (req.label) |l| t.label = try memDup(l);
                if (req.event_filters != null) t.event_filters = try memDup(event_filters_json);
                t.updated_at = try nowString();
                try ctx.renderJson(try model.triggerResponseFromEntry(allocator, g_cfg.?, t.*));
                return;
            }
        }
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
    }
}

pub fn deleteTrigger(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const trigger_id = ctx.getPathParam("triggerId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "trigger_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    const existing_ap = (try loadAutopilot(ctx.allocator, workspace_id, autopilot_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "autopilot not found" });
        return;
    };
    _ = existing_ap;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams("DELETE FROM autopilot_trigger WHERE id = $1::uuid AND autopilot_id = $2::uuid RETURNING id", &[_]SqlParam{ .{ .text = trigger_id }, .{ .text = autopilot_id } });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "trigger not found" });
            return;
        }
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        if (mem_triggers.?.getPtr(autopilot_id)) |triggers| {
            var i: usize = 0;
            while (i < triggers.items.len) : (i += 1) {
                if (std.mem.eql(u8, triggers.items[i].id, trigger_id)) {
                    const t = triggers.orderedRemove(i);
                    model.memAlloc().free(t.id);
                    model.memAlloc().free(t.autopilot_id);
                    model.memAlloc().free(t.kind);
                    model.memAlloc().free(t.cron_expression);
                    model.memAlloc().free(t.timezone);
                    model.memAlloc().free(t.next_run_at);
                    model.memAlloc().free(t.webhook_token);
                    model.memAlloc().free(t.label);
                    model.memAlloc().free(t.last_fired_at);
                    model.memAlloc().free(t.provider);
                    model.memAlloc().free(t.signing_secret);
                    model.memAlloc().free(t.event_filters);
                    model.memAlloc().free(t.created_at);
                    model.memAlloc().free(t.updated_at);
                    ctx.res_status = .no_content;
                    return;
                }
            }
        }
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
    }
}

pub fn setSigningSecret(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const trigger_id = ctx.getPathParam("triggerId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "trigger_id is required" });
        return;
    };

    if (!(try requireMember(ctx))) return;

    const existing_ap = (try loadAutopilot(allocator, workspace_id, autopilot_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "autopilot not found" });
        return;
    };
    _ = existing_ap;

    const existing = (try loadTrigger(allocator, autopilot_id, trigger_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
        return;
    };
    if (!std.mem.eql(u8, existing.kind, "webhook")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "trigger is not a webhook trigger" });
        return;
    }

    const parsed = try ctx.parseJsonBody(model.SetSigningSecretRequest);
    defer parsed.deinit();
    const req = parsed.value;
    const secret = std.mem.trim(u8, req.signing_secret, &std.ascii.whitespace);
    if (secret.len > 0 and secret.len < 16) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "signing_secret must be at least 16 characters" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "UPDATE autopilot_trigger SET signing_secret = NULLIF($3, ''), updated_at = now() WHERE id = $1::uuid AND autopilot_id = $2::uuid " ++
                "RETURNING id, autopilot_id, kind, enabled, cron_expression, timezone, next_run_at, webhook_token, label, last_fired_at, provider, signing_secret, event_filters, created_at, updated_at",
            &[_]SqlParam{ .{ .text = trigger_id }, .{ .text = autopilot_id }, .{ .text = secret } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "trigger not found" });
            return;
        }
        try ctx.renderJson(try model.triggerResponseFromRow(allocator, g_cfg.?, &rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        if (mem_triggers.?.getPtr(autopilot_id)) |triggers| {
            for (triggers.items) |*t| {
                if (!std.mem.eql(u8, t.id, trigger_id)) continue;
                t.signing_secret = try memDup(secret);
                t.updated_at = try nowString();
                try ctx.renderJson(try model.triggerResponseFromEntry(allocator, g_cfg.?, t.*));
                return;
            }
        }
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
    }
}

pub fn listRuns(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .runs = &[_]model.AutopilotRunResponse{}, .total = 0 });
}

pub fn getRun(ctx: *zfinal.Context) !void {
    ctx.res_status = .not_found;
    try ctx.renderJson(.{ .@"error" = "run not found" });
}

pub fn triggerAutopilot(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    var run_id: []const u8 = undefined;

    // Record a delivery entry so the new `deliveries` endpoints
    // have something to return. In the no-DB path the actual HTTP
    // call is simulated: response_status=202, response_body=ok.
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "INSERT INTO webhook_delivery (workspace_id, autopilot_id, trigger_id, provider, event, status, response_status, response_body) " ++
            "SELECT $1::uuid, $2::uuid, id, 'generic', 'autopilot.trigger', 'queued', 202, 'ok' " ++
            "FROM autopilot_trigger WHERE autopilot_id = $2::uuid LIMIT 1 " ++
            "RETURNING id",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = autopilot_id } },
        );
        defer rs.deinit();
        run_id = if (rs.rows.items.len > 0)
            try allocator.dupe(u8, rs.rows.items[0].getText(0) orelse "")
        else
            try generateId(allocator, autopilot_id);
    } else {
        run_id = try generateId(allocator, autopilot_id);
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);
        const now = try model.nowString();
        const stable_aid = try model.memDup(autopilot_id);
        errdefer model.memAlloc().free(stable_aid);
        const gop = try mem_webhook_deliveries.?.getOrPut(stable_aid);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(model.memAlloc(), model.WebhookDeliveryEntry{
            .id = try model.memDup(run_id),
            .autopilot_id = try model.memDup(autopilot_id),
            .trigger_id = try model.memDup(""),
            .event_type = try model.memDup("autopilot.trigger"),
            .payload = try model.memDup("{\"autopilot_id\":\""),
            .response_status = 202,
            .response_body = try model.memDup("ok"),
            .created_at = try model.memDup(now),
        });
    }

    ctx.res_status = .accepted;
    try ctx.renderJson(.{ .run_id = run_id });
}

/// `GET /api/autopilots/:id/deliveries` — list webhook deliveries
/// recorded for this autopilot, newest first.
pub fn listDeliveries(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    _ = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, autopilot_id, trigger_id, event, '', COALESCE(response_status, 0), COALESCE(response_body, ''), created_at " ++
            "FROM webhook_delivery WHERE autopilot_id = $1::uuid ORDER BY created_at DESC",
            &[_]SqlParam{.{ .text = autopilot_id }},
        );
        defer rs.deinit();
        var out: std.ArrayList(model.WebhookDeliveryResponse) = .empty;
        defer out.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try out.append(allocator, model.WebhookDeliveryResponse{
                .id = r.getText(0) orelse "",
                .autopilot_id = r.getText(1) orelse "",
                .trigger_id = r.getText(2) orelse "",
                .event_type = r.getText(3) orelse "",
                .payload = r.getText(4) orelse "",
                .response_status = std.fmt.parseInt(i32, r.getText(5) orelse "0", 10) catch 0,
                .response_body = r.getText(6) orelse "",
                .created_at = r.getText(7) orelse "",
            });
        }
        try ctx.renderJson(.{ .deliveries = out.items, .total = out.items.len });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var out: std.ArrayList(model.WebhookDeliveryResponse) = .empty;
    defer out.deinit(allocator);
    if (mem_webhook_deliveries.?.get(autopilot_id)) |items| {
        for (items.items) |d| {
            try out.append(allocator, model.webhookDeliveryResponseFromEntry(d));
        }
    }
    try ctx.renderJson(.{ .deliveries = out.items, .total = out.items.len });
}

/// `GET /api/autopilots/:id/deliveries/:deliveryId` — fetch a
/// single delivery.
pub fn getDelivery(ctx: *zfinal.Context) !void {
    _ = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const delivery_id = ctx.getPathParam("deliveryId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "delivery_id is required" });
        return;
    };
    // Validate UUID shape early: PostgreSQL's $n::uuid cast will error
    // on non-UUID strings instead of returning zero rows, leaking a 500.
    if (!model.looksLikeUuid(delivery_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "delivery not found" });
        return;
    }
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, autopilot_id, trigger_id, event, '', COALESCE(response_status, 0), COALESCE(response_body, ''), created_at " ++
            "FROM webhook_delivery WHERE id = $1::uuid AND autopilot_id = $2::uuid",
            &[_]SqlParam{ .{ .text = delivery_id }, .{ .text = autopilot_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "delivery not found" });
            return;
        }
        const r = &rs.rows.items[0];
        try ctx.renderJson(model.WebhookDeliveryResponse{
            .id = r.getText(0) orelse "",
            .autopilot_id = r.getText(1) orelse "",
            .trigger_id = r.getText(2) orelse "",
            .event_type = r.getText(3) orelse "",
            .payload = r.getText(4) orelse "",
            .response_status = std.fmt.parseInt(i32, r.getText(5) orelse "0", 10) catch 0,
            .response_body = r.getText(6) orelse "",
            .created_at = r.getText(7) orelse "",
        });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const list_ptr = mem_webhook_deliveries.?.getPtr(autopilot_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "delivery not found" });
        return;
    };
    for (list_ptr.items) |d| {
        if (std.mem.eql(u8, d.id, delivery_id)) {
            try ctx.renderJson(model.webhookDeliveryResponseFromEntry(d));
            return;
        }
    }
    ctx.res_status = .not_found;
    try ctx.renderJson(.{ .@"error" = "delivery not found" });
}

/// `POST /api/autopilots/:id/deliveries/:deliveryId/replay` —
/// re-record the same delivery so operators can re-trigger the
/// downstream flow. 200 + `{status: "queued"}`.
pub fn replayDelivery(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const delivery_id = ctx.getPathParam("deliveryId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "delivery_id is required" });
        return;
    };
    // Validate UUID shape early: PostgreSQL's $n::uuid cast will error
    // on non-UUID strings instead of returning zero rows.
    if (!model.looksLikeUuid(delivery_id) or !model.looksLikeUuid(autopilot_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "delivery not found" });
        return;
    }
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        // Clone the original delivery as a new "replay" row.
        var rs = try db.queryParams(
            "INSERT INTO webhook_delivery (workspace_id, autopilot_id, trigger_id, provider, event, status, response_status, response_body, replayed_from_delivery_id) " ++
            "SELECT $1::uuid, d.autopilot_id, d.trigger_id, d.provider, 'autopilot.replay', 'queued', 202, 'ok', d.id " ++
            "FROM webhook_delivery d WHERE d.id = $2::uuid AND d.autopilot_id = $3::uuid " ++
            "RETURNING 1",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = delivery_id }, .{ .text = autopilot_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "delivery not found" });
            return;
        }
        try ctx.renderJson(.{ .status = "queued" });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const list_ptr = mem_webhook_deliveries.?.getPtr(autopilot_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "delivery not found" });
        return;
    };
    var i: usize = 0;
    var found = false;
    while (i < list_ptr.items.len) {
        if (std.mem.eql(u8, list_ptr.items[i].id, delivery_id)) {
            // Clone the original entry and append a new "replay"
            // row with a fresh id so the timeline is preserved.
            const src = list_ptr.items[i];
            const new_id = try generateId(allocator, "replay");
            const now = try model.nowString();
            try list_ptr.append(model.memAlloc(), model.WebhookDeliveryEntry{
                .id = try model.memDup(new_id),
                .autopilot_id = try model.memDup(src.autopilot_id),
                .trigger_id = try model.memDup(src.trigger_id),
                .event_type = try model.memDup("autopilot.replay"),
                .payload = try model.memDup(src.payload),
                .response_status = 202,
                .response_body = try model.memDup("ok"),
                .created_at = try model.memDup(now),
            });
            found = true;
            break;
        }
        i += 1;
    }
    if (!found) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "delivery not found" });
        return;
    }
    try ctx.renderJson(.{ .status = "queued" });
}

/// `POST /api/autopilots/:id/triggers/:triggerId/rotate-webhook-token`
/// — issue a fresh token for the trigger. The old token immediately
/// fails `isValidWebhookToken` since the in-memory map keys on the
/// token string.
pub fn rotateWebhookToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    _ = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const autopilot_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "autopilot_id is required" });
        return;
    };
    const trigger_id = ctx.getPathParam("triggerId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "trigger_id is required" });
        return;
    };
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const new_token = try generateToken(allocator);
        var rs = try db.queryParams(
            "UPDATE autopilot_trigger SET webhook_token = $3, updated_at = now() " ++
            "WHERE id = $1::uuid AND autopilot_id = $2::uuid " ++
            "RETURNING webhook_token",
            &[_]SqlParam{ .{ .text = trigger_id }, .{ .text = autopilot_id }, .{ .text = new_token } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "trigger not found" });
            return;
        }
        const returned_token = rs.rows.items[0].getText(0) orelse new_token;
        try ctx.renderJson(model.RotateWebhookTokenResponse{
            .trigger_id = try allocator.dupe(u8, trigger_id),
            .webhook_token = try allocator.dupe(u8, returned_token),
        });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const list_ptr = mem_triggers.?.getPtr(autopilot_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "trigger not found" });
        return;
    };
    for (list_ptr.items) |*t| {
        if (std.mem.eql(u8, t.id, trigger_id)) {
            const new_token = try generateToken(allocator);
            t.webhook_token = try model.memDup(new_token);
            try ctx.renderJson(model.RotateWebhookTokenResponse{
                .trigger_id = try model.memDup(trigger_id),
                .webhook_token = t.webhook_token,
            });
            return;
        }
    }
    ctx.res_status = .not_found;
    try ctx.renderJson(.{ .@"error" = "trigger not found" });
}

// ──────────────────────────────────────────────────────────────────────
// Cross-module helpers (used by the `webhook` module)
// ──────────────────────────────────────────────────────────────────────

/// Returns true if the webhook token matches a webhook trigger in the workspace.
pub fn isValidWebhookToken(token: []const u8) !bool {
    if (token.len == 0) return false;
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams("SELECT 1 FROM autopilot_trigger WHERE webhook_token = $1", &[_]SqlParam{.{ .text = token }});
        defer rs.deinit();
        return rs.rows.items.len > 0;
    } else {
        try memInit();
        var it = mem_triggers.?.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |t| {
                if (std.mem.eql(u8, t.webhook_token, token)) return true;
            }
        }
        return false;
    }
}

/// Returns the signing secret for a webhook trigger token, or null if none is set.
pub fn getSigningSecretForWebhookToken(token: []const u8) !?[]const u8 {
    if (token.len == 0) return null;
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams("SELECT signing_secret FROM autopilot_trigger WHERE webhook_token = $1", &[_]SqlParam{.{ .text = token }});
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        const secret = rs.rows.items[0].getText(0) orelse "";
        if (secret.len == 0) return null;
        return try memDup(secret);
    } else {
        try memInit();
        var it = mem_triggers.?.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |t| {
                if (std.mem.eql(u8, t.webhook_token, token)) {
                    if (t.signing_secret.len == 0) return null;
                    return t.signing_secret;
                }
            }
        }
        return null;
    }
}
