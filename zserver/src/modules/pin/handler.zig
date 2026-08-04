//! Pin module — thin HTTP delegates.
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

pub fn listPins(ctx: *zfinal.Context) !void {
    try service.listPins(ctx);
}

pub fn createPin(ctx: *zfinal.Context) !void {
    try service.createPin(ctx);
}

pub fn deletePin(ctx: *zfinal.Context) !void {
    try service.deletePin(ctx);
}

pub fn reorderPins(ctx: *zfinal.Context) !void {
    try service.reorderPins(ctx);
}
