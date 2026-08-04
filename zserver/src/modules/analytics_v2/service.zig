//! Analytics V2 module — business logic.
//!
//! Provides in-memory metric tracking, time-series queries,
//! and report generation. No database is used; all data lives
//! in a mutex-protected ArrayList within the process.
//!
//! Endpoints:
//!   POST /api/analytics/track    — record a metric
//!   GET  /api/analytics/query    — time-series query
//!   POST /api/analytics/reports  — generate a report
//!   GET  /api/analytics/reports  — list reports
//!   GET  /api/analytics/reports/:id — get single report

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");

const log = std.log.scoped(.analytics_v2_service);

/// In-memory metric storage. Protected by a mutex for thread safety.
var metrics_mutex: std.Io.Mutex = std.Io.Mutex.init;
var metrics: std.ArrayList(model.Metric) = .empty;

/// In-memory report storage. Protected by a mutex for thread safety.
var reports_mutex: std.Io.Mutex = std.Io.Mutex.init;
var reports: std.ArrayList(model.Report) = .empty;

/// Monotonic report id counter.
var next_report_id: usize = 1;

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

/// POST /api/analytics/track
/// Body: { name, value, labels? }
/// Stores the metric in-memory under the caller's workspace.
pub fn trackMetric(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const body = try ctx.getBodyText();
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid JSON body" });
        return;
    };
    defer parsed.deinit();

    const val = parsed.value;
    const obj = if (val == .object) val.object else {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request body must be a JSON object" });
        return;
    };

    const name_raw = obj.get("name");
    const name_str: ?[]const u8 = if (name_raw) |n| blk: {
        if (n == .string) break :blk n.string;
        break :blk null;
    } else null;
    if (name_str == null or name_str.?.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }
    const name = name_str.?;

    const value = blk: {
        if (obj.get("value")) |v| {
            if (v == .float) break :blk v.float;
            if (v == .integer) break :blk @as(f64, @floatFromInt(v.integer));
            if (v == .number_string) {
                const f = std.fmt.parseFloat(f64, v.number_string) catch break :blk @as(f64, 0);
                break :blk f;
            }
        }
        break :blk @as(f64, 0);
    };

    const labels_json = blk: {
        if (obj.get("labels")) |v| {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            if (v == .null) break :blk null;
        }
        break :blk null;
    };

    const now = @as(i64, @intCast(std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds()));

    const metric = model.Metric{
        .name = try allocator.dupe(u8, name),
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .value = value,
        .labels_json = labels_json,
        .timestamp = now,
    };

    {
        try metrics_mutex.lock(zfinal.io_instance.io);
        defer metrics_mutex.unlock(zfinal.io_instance.io);
        try metrics.append(allocator, metric);
    }

    try ctx.renderJson(.{
        .ok = true,
        .metric = .{
            .name = metric.name,
            .value = metric.value,
            .labels_json = metric.labels_json,
            .timestamp = metric.timestamp,
        },
    });
}

/// GET /api/analytics/query?name=X&from=TS&to=TS
/// Returns time-series data points matching the filters.
pub fn queryMetrics(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const name_filter = try ctx.getPara("name");
    const from_str = try ctx.getPara("from");
    const to_str = try ctx.getPara("to");

    const from_ts: i64 = if (from_str) |s| std.fmt.parseInt(i64, s, 10) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid from timestamp" });
        return;
    } else 0;

    const to_ts: i64 = if (to_str) |s| std.fmt.parseInt(i64, s, 10) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid to timestamp" });
        return;
    } else std.math.maxInt(i64);

    var result: std.ArrayList(model.TimeSeriesPoint) = .empty;

    {
        try metrics_mutex.lock(zfinal.io_instance.io);
        defer metrics_mutex.unlock(zfinal.io_instance.io);

        for (metrics.items) |m| {
            if (!std.mem.eql(u8, m.workspace_id, workspace_id)) continue;
            if (name_filter) |nf| {
                if (!std.mem.eql(u8, m.name, nf)) continue;
            }
            if (m.timestamp < from_ts) continue;
            if (m.timestamp > to_ts) continue;

            try result.append(allocator, model.TimeSeriesPoint{
                .name = try allocator.dupe(u8, m.name),
                .value = m.value,
                .labels_json = if (m.labels_json) |l| try allocator.dupe(u8, l) else null,
                .timestamp = m.timestamp,
            });
        }
    }

    try ctx.renderJson(.{ .points = result.items });
}

/// Compute summary statistics from a slice of TimeSeriesPoint values.
fn computeSummary(pts: []const model.TimeSeriesPoint) model.SummaryData {
    if (pts.len == 0) {
        return model.SummaryData{
            .total_metrics = 0,
            .avg_value = 0,
            .min_value = 0,
            .max_value = 0,
        };
    }

    var sum: f64 = 0;
    var min: f64 = pts[0].value;
    var max: f64 = pts[0].value;

    for (pts) |p| {
        sum += p.value;
        if (p.value < min) min = p.value;
        if (p.value > max) max = p.value;
    }

    return model.SummaryData{
        .total_metrics = pts.len,
        .avg_value = sum / @as(f64, @floatFromInt(pts.len)),
        .min_value = min,
        .max_value = max,
    };
}

/// POST /api/analytics/reports
/// Body: { name, metrics[], from_ts, to_ts, format? }
/// Generates a report with summary data from matching metrics.
pub fn generateReport(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const body = try ctx.getBodyText();
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid JSON body" });
        return;
    };
    defer parsed.deinit();

    const val = parsed.value;
    const obj = if (val == .object) val.object else {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request body must be a JSON object" });
        return;
    };

    const name_val = obj.get("name") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    };
    const name_str = if (name_val == .string) name_val.string else null;
    if (name_str == null or name_str.?.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }
    const report_name = name_str.?;

    // Parse metrics array
    const metrics_val = obj.get("metrics") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "metrics is required" });
        return;
    };
    if (metrics_val != .array) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "metrics must be an array" });
        return;
    }

    var metric_names: std.ArrayList([]const u8) = .empty;
    for (metrics_val.array.items) |m| {
        if (m == .string) {
            try metric_names.append(allocator, try allocator.dupe(u8, m.string));
        }
    }

    const from_ts: i64 = blk: {
        if (obj.get("from_ts")) |v| {
            if (v == .integer) break :blk v.integer;
            if (v == .float) break :blk @as(i64, @intFromFloat(v.float));
            if (v == .number_string) {
                const n = std.fmt.parseInt(i64, v.number_string, 10) catch break :blk @as(i64, 0);
                break :blk n;
            }
        }
        break :blk @as(i64, 0);
    };

    const to_ts: i64 = blk: {
        if (obj.get("to_ts")) |v| {
            if (v == .integer) break :blk v.integer;
            if (v == .float) break :blk @as(i64, @intFromFloat(v.float));
            if (v == .number_string) {
                const n = std.fmt.parseInt(i64, v.number_string, 10) catch break :blk std.math.maxInt(i64);
                break :blk n;
            }
        }
        break :blk std.math.maxInt(i64);
    };

    const fmt_str: []const u8 = blk: {
        if (obj.get("format")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "json";
    };

    // Collect matching metrics
    var matched: std.ArrayList(model.TimeSeriesPoint) = .empty;

    {
        try metrics_mutex.lock(zfinal.io_instance.io);
        defer metrics_mutex.unlock(zfinal.io_instance.io);

        for (metrics.items) |m| {
            if (!std.mem.eql(u8, m.workspace_id, workspace_id)) continue;

            var name_match = false;
            for (metric_names.items) |mn| {
                if (std.mem.eql(u8, m.name, mn)) {
                    name_match = true;
                    break;
                }
            }
            if (!name_match) continue;
            if (m.timestamp < from_ts) continue;
            if (m.timestamp > to_ts) continue;

            try matched.append(allocator, model.TimeSeriesPoint{
                .name = try allocator.dupe(u8, m.name),
                .value = m.value,
                .labels_json = if (m.labels_json) |l| try allocator.dupe(u8, l) else null,
                .timestamp = m.timestamp,
            });
        }
    }

    const report_format: model.ReportFormat = if (std.mem.eql(u8, fmt_str, "csv"))
        .csv
    else if (std.mem.eql(u8, fmt_str, "pdf"))
        .pdf
    else
        .json;

    const summary = computeSummary(matched.items);

    // Allocate report id
    var rid_buf: [32]u8 = undefined;
    const rid: usize = blk: {
        try reports_mutex.lock(zfinal.io_instance.io);
        defer reports_mutex.unlock(zfinal.io_instance.io);
        const id = next_report_id;
        next_report_id += 1;
        break :blk id;
    };
    const rid_str = try std.fmt.bufPrint(&rid_buf, "rpt_{d}", .{rid});

    const report = model.Report{
        .id = try allocator.dupe(u8, rid_str),
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .name = try allocator.dupe(u8, report_name),
        .metrics = metric_names.items,
        .date_range = .{ .from_ts = from_ts, .to_ts = to_ts },
        .format = report_format,
        .status = "completed",
    };

    {
        try reports_mutex.lock(zfinal.io_instance.io);
        defer reports_mutex.unlock(zfinal.io_instance.io);
        try reports.append(allocator, report);
    }

    try ctx.renderJson(model.GenerateReportResponse{
        .id = report.id,
        .name = report.name,
        .metrics = report.metrics,
        .from_ts = report.date_range.from_ts,
        .to_ts = report.date_range.to_ts,
        .format = @tagName(report.format),
        .status = report.status,
        .summary = summary,
    });
}

/// GET /api/analytics/reports
/// Lists all reports for the caller's workspace.
pub fn listReports(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    var result: std.ArrayList(model.Report) = .empty;

    {
        try reports_mutex.lock(zfinal.io_instance.io);
        defer reports_mutex.unlock(zfinal.io_instance.io);

        for (reports.items) |r| {
            if (std.mem.eql(u8, r.workspace_id, workspace_id)) {
                try result.append(allocator, r);
            }
        }
    }

    try ctx.renderJson(.{ .reports = result.items });
}

/// GET /api/analytics/reports/:id
/// Returns a single report with its data points and summary.
pub fn getReport(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const rid = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing report id" });
        return;
    };

    // Find the report
    var report_opt: ?model.Report = null;
    {
        try reports_mutex.lock(zfinal.io_instance.io);
        defer reports_mutex.unlock(zfinal.io_instance.io);

        for (reports.items) |r| {
            if (std.mem.eql(u8, r.id, rid) and std.mem.eql(u8, r.workspace_id, workspace_id)) {
                report_opt = r;
                break;
            }
        }
    }

    const report = report_opt orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "report not found" });
        return;
    };

    // Collect matching points for this report
    var points: std.ArrayList(model.TimeSeriesPoint) = .empty;

    {
        try metrics_mutex.lock(zfinal.io_instance.io);
        defer metrics_mutex.unlock(zfinal.io_instance.io);

        for (metrics.items) |m| {
            if (!std.mem.eql(u8, m.workspace_id, workspace_id)) continue;

            var name_match = false;
            for (report.metrics) |mn| {
                if (std.mem.eql(u8, m.name, mn)) {
                    name_match = true;
                    break;
                }
            }
            if (!name_match) continue;
            if (m.timestamp < report.date_range.from_ts) continue;
            if (m.timestamp > report.date_range.to_ts) continue;

            try points.append(allocator, model.TimeSeriesPoint{
                .name = try allocator.dupe(u8, m.name),
                .value = m.value,
                .labels_json = if (m.labels_json) |l| try allocator.dupe(u8, l) else null,
                .timestamp = m.timestamp,
            });
        }
    }

    const summary = computeSummary(points.items);

    try ctx.renderJson(model.GetReportResponse{
        .id = report.id,
        .workspace_id = report.workspace_id,
        .name = report.name,
        .metrics = report.metrics,
        .from_ts = report.date_range.from_ts,
        .to_ts = report.date_range.to_ts,
        .format = @tagName(report.format),
        .status = report.status,
        .points = points.items,
        .summary = summary,
    });
}
