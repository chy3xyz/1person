//! Label module — thin HTTP delegates.
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

pub fn listLabels(ctx: *zfinal.Context) !void {
    try service.listLabels(ctx);
}

pub fn getLabel(ctx: *zfinal.Context) !void {
    try service.getLabel(ctx);
}

pub fn createLabel(ctx: *zfinal.Context) !void {
    try service.createLabel(ctx);
}

pub fn updateLabel(ctx: *zfinal.Context) !void {
    try service.updateLabel(ctx);
}

pub fn deleteLabel(ctx: *zfinal.Context) !void {
    try service.deleteLabel(ctx);
}
