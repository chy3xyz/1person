//! Analytics V2 module — data layer.
//!
//! Provides the data structs for the advanced analytics engine.
//! All storage is in-memory (no-DB). The service layer manages
//! thread-safe access via a mutex-protected ArrayList.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// A single tracked metric data point.
pub const Metric = struct {
    name: []const u8,
    workspace_id: []const u8,
    value: f64,
    labels_json: ?[]const u8,
    timestamp: i64,
};

/// The date range for a report query.
pub const DateRange = struct {
    from_ts: i64,
    to_ts: i64,
};

/// Supported report output formats.
pub const ReportFormat = enum {
    csv,
    pdf,
    json,
};

/// An analytics report.
pub const Report = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    metrics: []const []const u8,
    date_range: DateRange,
    format: ReportFormat,
    status: []const u8,
};

/// A single data point returned by the query endpoint.
pub const TimeSeriesPoint = struct {
    name: []const u8,
    value: f64,
    labels_json: ?[]const u8,
    timestamp: i64,
};

/// The response shape for GET /api/analytics/query.
pub const QueryResponse = struct {
    points: []const TimeSeriesPoint,
};

/// The request shape for POST /api/analytics/track.
pub const TrackRequest = struct {
    name: []const u8,
    value: f64,
    labels: ?[]const u8,
};

/// The request shape for POST /api/analytics/reports.
pub const GenerateReportRequest = struct {
    name: []const u8,
    metrics: []const []const u8,
    from_ts: i64,
    to_ts: i64,
    format: ?[]const u8,
};

/// The response shape for POST /api/analytics/reports.
pub const GenerateReportResponse = struct {
    id: []const u8,
    name: []const u8,
    metrics: []const []const u8,
    from_ts: i64,
    to_ts: i64,
    format: []const u8,
    status: []const u8,
    summary: SummaryData,
};

/// Summary statistics included in every report.
pub const SummaryData = struct {
    total_metrics: usize,
    avg_value: f64,
    min_value: f64,
    max_value: f64,
};

/// The response shape for GET /api/analytics/reports.
pub const ListReportsResponse = struct {
    reports: []const Report,
};

/// The response shape for GET /api/analytics/reports/:id.
pub const GetReportResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    metrics: []const []const u8,
    from_ts: i64,
    to_ts: i64,
    format: []const u8,
    status: []const u8,
    points: []const TimeSeriesPoint,
    summary: SummaryData,
};
