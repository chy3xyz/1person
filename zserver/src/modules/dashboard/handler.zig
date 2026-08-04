//! Dashboard module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn init(cfg: *const Config) void {
    service.init(cfg);
}

pub fn getDashboardUsageDaily(ctx: *zfinal.Context) !void {
    try service.getDashboardUsageDaily(ctx);
}

pub fn getDashboardUsageByAgent(ctx: *zfinal.Context) !void {
    try service.getDashboardUsageByAgent(ctx);
}

pub fn getDashboardAgentRunTime(ctx: *zfinal.Context) !void {
    try service.getDashboardAgentRunTime(ctx);
}

pub fn getDashboardRunTimeDaily(ctx: *zfinal.Context) !void {
    try service.getDashboardRunTimeDaily(ctx);
}

pub fn getDashboardConfig(ctx: *zfinal.Context) !void {
    try service.getDashboardConfig(ctx);
}

pub fn getDashboardData(ctx: *zfinal.Context) !void {
    try service.getDashboardData(ctx);
}
