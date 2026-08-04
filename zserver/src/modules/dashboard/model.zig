//! Dashboard module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and the escape-hatch SQL helpers. The dashboard
//! surface is read-only: every endpoint is a SELECT against
//! `task_usage_hourly` / `agent_task_queue` / `agent` aggregated for
//! the caller's workspace. There is no in-memory fallback store — the
//! no-DB branch returns an empty list so smoke tests still get a
//! well-formed JSON array.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

/// One row of `GET /api/dashboard/usage/daily`.
pub const DashboardUsageDailyResponse = struct {
    date: []const u8,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    task_count: i32,
};

/// One row of `GET /api/dashboard/usage/by-agent`.
pub const DashboardUsageByAgentResponse = struct {
    agent_id: []const u8,
    model: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    task_count: i32,
};

/// One row of `GET /api/dashboard/agent-runtime`.
pub const DashboardAgentRunTimeResponse = struct {
    agent_id: []const u8,
    total_seconds: i64,
    task_count: i32,
    failed_count: i32,
};

/// One row of `GET /api/dashboard/runtime/daily`.
pub const DashboardRunTimeDailyResponse = struct {
    date: []const u8,
    total_seconds: i64,
    task_count: i32,
    failed_count: i32,
};

/// Parse a bigint cell that comes back as text from `zfinal.DB`.
/// Returns 0 when the cell is NULL or non-numeric.
pub fn parseBigInt(text: ?[]const u8) i64 {
    const t = text orelse return 0;
    return std.fmt.parseInt(i64, t, 10) catch 0;
}

// ── V2 config & widget shapes ──────────────────────────────────────

/// One widget entry in the dashboard config.
pub const DashboardWidget = struct {
    name: []const u8,
    kind: []const u8, // bar_chart | line_chart | stat_card | table
    title: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// The full dashboard config returned by GET /api/dashboard/config.
pub const DashboardConfigResponse = struct {
    widgets: []const DashboardWidget,
};

/// A single dataset within a chart widget's data payload.
pub const ChartDataset = struct {
    label: []const u8,
    data: []const i64,
};

/// Widget data for bar_chart / line_chart widgets.
pub const ChartWidgetData = struct {
    labels: []const []const u8,
    datasets: []const ChartDataset,
};

/// Widget data for a stat_card widget.
pub const StatCardWidgetData = struct {
    value: []const u8,
    label: []const u8,
    trend: f64,
    trend_direction: []const u8, // "up" | "down"
};

/// Widget data for a table widget.
pub const TableWidgetData = struct {
    columns: []const []const u8,
    rows: []const []const []const u8,
};
