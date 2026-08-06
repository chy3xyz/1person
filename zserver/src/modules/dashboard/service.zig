//! Dashboard module — business logic.
//!
//! Owns the process-wide `g_cfg` pointer set once at startup by
//! `handler.init`. The four HTTP-facing operations are
//! `getDashboardUsageDaily`, `getDashboardUsageByAgent`,
//! `getDashboardAgentRunTime`, `getDashboardRunTimeDaily`. They share
//! the same shape: a workspace-scoped aggregate query against
//! `task_usage_hourly` / `agent_task_queue`, with an empty-array
//! fallback when the DB is unconfigured. `handler.zig` is a thin
//! delegate; SQL and response shapes live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const SqlParam = zfinal.SqlParam;
const model = @import("model.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.dashboard_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

pub fn getDashboardUsageDaily(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT to_char(date_trunc('day', bucket_hour)::date, 'YYYY-MM-DD') AS date, " ++
                "model, SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), " ++
                "SUM(cache_write_tokens), SUM(task_count) " ++
                "FROM task_usage_hourly WHERE workspace_id = $1::uuid " ++
                "GROUP BY date_trunc('day', bucket_hour)::date, model " ++
                "ORDER BY date DESC",
            &[_]SqlParam{.{ .text = workspace_id }},
        ) catch {
            try ctx.renderJson(&[_]model.DashboardUsageDailyResponse{});
            return;
        };
        defer rs.deinit();
        var list: std.ArrayList(model.DashboardUsageDailyResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.DashboardUsageDailyResponse{
                .date = r.getText(0) orelse "",
                .model = r.getText(1) orelse "",
                .input_tokens = model.parseBigInt(r.getText(2)),
                .output_tokens = model.parseBigInt(r.getText(3)),
                .cache_read_tokens = model.parseBigInt(r.getText(4)),
                .cache_write_tokens = model.parseBigInt(r.getText(5)),
                .task_count = @intCast(model.parseBigInt(r.getText(6))),
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try ctx.renderJson(&[_]model.DashboardUsageDailyResponse{});
    }
}

pub fn getDashboardUsageByAgent(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "SELECT agent_id, model, SUM(input_tokens), SUM(output_tokens), " ++
                "SUM(cache_read_tokens), SUM(cache_write_tokens), SUM(task_count) " ++
                "FROM task_usage_hourly WHERE workspace_id = $1::uuid " ++
                "GROUP BY agent_id, model",
            &[_]SqlParam{.{ .text = workspace_id }},
        ) catch {
            try ctx.renderJson(&[_]model.DashboardUsageByAgentResponse{});
            return;
        };
        defer rs.deinit();
        var list: std.ArrayList(model.DashboardUsageByAgentResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.DashboardUsageByAgentResponse{
                .agent_id = r.getText(0) orelse "",
                .model = r.getText(1) orelse "",
                .input_tokens = model.parseBigInt(r.getText(2)),
                .output_tokens = model.parseBigInt(r.getText(3)),
                .cache_read_tokens = model.parseBigInt(r.getText(4)),
                .cache_write_tokens = model.parseBigInt(r.getText(5)),
                .task_count = @intCast(model.parseBigInt(r.getText(6))),
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try ctx.renderJson(&[_]model.DashboardUsageByAgentResponse{});
    }
}

pub fn getDashboardAgentRunTime(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT atq.agent_id, " ++
                "COALESCE(SUM(EXTRACT(EPOCH FROM (atq.completed_at - atq.started_at)))::bigint, 0), " ++
                "COUNT(*) FILTER (WHERE atq.status IN ('completed','failed')), " ++
                "COUNT(*) FILTER (WHERE atq.status = 'failed') " ++
                "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
                "WHERE a.workspace_id = $1::uuid AND atq.started_at IS NOT NULL AND atq.completed_at IS NOT NULL " ++
                "GROUP BY atq.agent_id",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.DashboardAgentRunTimeResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.DashboardAgentRunTimeResponse{
                .agent_id = r.getText(0) orelse "",
                .total_seconds = model.parseBigInt(r.getText(1)),
                .task_count = @intCast(model.parseBigInt(r.getText(2))),
                .failed_count = @intCast(model.parseBigInt(r.getText(3))),
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try ctx.renderJson(&[_]model.DashboardAgentRunTimeResponse{});
    }
}

pub fn getDashboardRunTimeDaily(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT to_char(date_trunc('day', atq.completed_at)::date, 'YYYY-MM-DD') AS date, " ++
                "COALESCE(SUM(EXTRACT(EPOCH FROM (atq.completed_at - atq.started_at)))::bigint, 0), " ++
                "COUNT(*) FILTER (WHERE atq.status IN ('completed','failed')), " ++
                "COUNT(*) FILTER (WHERE atq.status = 'failed') " ++
                "FROM agent_task_queue atq JOIN agent a ON a.id = atq.agent_id " ++
                "WHERE a.workspace_id = $1::uuid AND atq.started_at IS NOT NULL AND atq.completed_at IS NOT NULL " ++
                "GROUP BY date_trunc('day', atq.completed_at)::date " ++
                "ORDER BY date DESC",
            &[_]SqlParam{.{ .text = workspace_id }},
        );
        defer rs.deinit();
        var list: std.ArrayList(model.DashboardRunTimeDailyResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            const r = &rs.rows.items[i];
            try list.append(allocator, model.DashboardRunTimeDailyResponse{
                .date = r.getText(0) orelse "",
                .total_seconds = model.parseBigInt(r.getText(1)),
                .task_count = @intCast(model.parseBigInt(r.getText(2))),
                .failed_count = @intCast(model.parseBigInt(r.getText(3))),
            });
        }
        try ctx.renderJson(list.items);
    } else {
        try ctx.renderJson(&[_]model.DashboardRunTimeDailyResponse{});
    }
}

// ── V2: configurable analytics dashboard ───────────────────────────

/// GET /api/dashboard/config — returns a static JSON config with widget
/// layout definitions.
pub fn getDashboardConfig(ctx: *zfinal.Context) !void {
    const widgets = [_]model.DashboardWidget{
        .{ .name = "revenue", .kind = "bar_chart", .title = "Revenue", .x = 0, .y = 0, .w = 6, .h = 4 },
        .{ .name = "users", .kind = "line_chart", .title = "Active Users", .x = 6, .y = 0, .w = 6, .h = 4 },
        .{ .name = "tasks", .kind = "stat_card", .title = "Tasks Completed", .x = 0, .y = 4, .w = 3, .h = 2 },
        .{ .name = "errors", .kind = "stat_card", .title = "Errors", .x = 3, .y = 4, .w = 3, .h = 2 },
        .{ .name = "recent_issues", .kind = "table", .title = "Recent Issues", .x = 6, .y = 4, .w = 6, .h = 4 },
    };
    try ctx.renderJson(.{ .widgets = &widgets });
}

fn mockRevenueData() model.ChartWidgetData {
    return .{
        .labels = &[_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" },
        .datasets = &[_]model.ChartDataset{
            .{ .label = "Subscription", .data = &[_]i64{ 1200, 1350, 1500, 1480, 1620, 1750 } },
            .{ .label = "One-time", .data = &[_]i64{ 400, 380, 420, 390, 450, 410 } },
        },
    };
}

fn mockUsersData() model.ChartWidgetData {
    return .{
        .labels = &[_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" },
        .datasets = &[_]model.ChartDataset{
            .{ .label = "DAU", .data = &[_]i64{ 890, 920, 1050, 1100, 1080, 1150 } },
            .{ .label = "MAU", .data = &[_]i64{ 3200, 3400, 3600, 3750, 3900, 4100 } },
        },
    };
}

fn mockTasksData() model.StatCardWidgetData {
    return .{ .value = "1,247", .label = "Tasks Completed", .trend = 12.5, .trend_direction = "up" };
}

fn mockErrorsData() model.StatCardWidgetData {
    return .{ .value = "23", .label = "Errors", .trend = 8.3, .trend_direction = "down" };
}

fn mockRecentIssuesData() model.TableWidgetData {
    return .{
        .columns = &[_][]const u8{ "ID", "Title", "Status", "Assignee" },
        .rows = &[_][]const []const u8{
            &[_][]const u8{ "#4012", "Fix login timeout", "open", "alice" },
            &[_][]const u8{ "#4011", "Update billing page", "in_progress", "bob" },
            &[_][]const u8{ "#4010", "Add dark mode", "done", "carol" },
            &[_][]const u8{ "#4009", "Refactor auth module", "open", "dave" },
        },
    };
}

/// GET /api/dashboard/widget/:name — returns mock data for the named
/// widget. Unknown names get a 404.
pub fn getDashboardData(ctx: *zfinal.Context) !void {
    const name = ctx.getPathParam("name") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing widget name" });
        return;
    };

    if (std.mem.eql(u8, name, "revenue")) {
        try ctx.renderJson(mockRevenueData());
    } else if (std.mem.eql(u8, name, "users")) {
        try ctx.renderJson(mockUsersData());
    } else if (std.mem.eql(u8, name, "tasks")) {
        try ctx.renderJson(mockTasksData());
    } else if (std.mem.eql(u8, name, "errors")) {
        try ctx.renderJson(mockErrorsData());
    } else if (std.mem.eql(u8, name, "recent_issues")) {
        try ctx.renderJson(mockRecentIssuesData());
    } else {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "widget not found" });
    }
}
