//! Analytics V2 module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn trackMetric(ctx: *zfinal.Context) !void {
    try service.trackMetric(ctx);
}

pub fn queryMetrics(ctx: *zfinal.Context) !void {
    try service.queryMetrics(ctx);
}

pub fn generateReport(ctx: *zfinal.Context) !void {
    try service.generateReport(ctx);
}

pub fn listReports(ctx: *zfinal.Context) !void {
    try service.listReports(ctx);
}

pub fn getReport(ctx: *zfinal.Context) !void {
    try service.getReport(ctx);
}
