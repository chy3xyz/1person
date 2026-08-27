//! Connector module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn createConfig(ctx: *zfinal.Context) !void {
    try service.createConfig(ctx);
}

pub fn listConfigs(ctx: *zfinal.Context) !void {
    try service.listConfigs(ctx);
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    try service.getConfig(ctx);
}

pub fn updateConfig(ctx: *zfinal.Context) !void {
    try service.updateConfig(ctx);
}

pub fn deleteConfig(ctx: *zfinal.Context) !void {
    try service.deleteConfig(ctx);
}

pub fn call(ctx: *zfinal.Context) !void {
    try service.call(ctx);
}

pub fn listLogs(ctx: *zfinal.Context) !void {
    try service.listLogs(ctx);
}
