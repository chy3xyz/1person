//! Media module — thin HTTP delegates.
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

pub fn upload(ctx: *zfinal.Context) !void {
    try service.upload(ctx);
}

pub fn list(ctx: *zfinal.Context) !void {
    try service.list(ctx);
}

pub fn get(ctx: *zfinal.Context) !void {
    try service.get(ctx);
}

pub fn deleteAsset(ctx: *zfinal.Context) !void {
    try service.deleteAsset(ctx);
}
