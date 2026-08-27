//! Task Queue V2 module — thin HTTP delegates.
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

pub fn enqueue(ctx: *zfinal.Context) !void {
    try service.enqueue(ctx);
}

pub fn claim(ctx: *zfinal.Context) !void {
    try service.claim(ctx);
}

pub fn start(ctx: *zfinal.Context) !void {
    try service.start(ctx);
}

pub fn complete(ctx: *zfinal.Context) !void {
    try service.complete(ctx);
}

pub fn fail(ctx: *zfinal.Context) !void {
    try service.fail(ctx);
}

pub fn retry(ctx: *zfinal.Context) !void {
    try service.retry(ctx);
}

pub fn list(ctx: *zfinal.Context) !void {
    try service.list(ctx);
}

pub fn queueStats(ctx: *zfinal.Context) !void {
    try service.queueStats(ctx);
}
