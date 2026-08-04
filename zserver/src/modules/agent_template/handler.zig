//! Agent template module — thin HTTP delegates.
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

pub fn listTemplates(ctx: *zfinal.Context) !void {
    try service.listTemplates(ctx);
}

pub fn getTemplate(ctx: *zfinal.Context) !void {
    try service.getTemplate(ctx);
}

pub fn createTemplate(ctx: *zfinal.Context) !void {
    try service.createTemplate(ctx);
}

pub fn updateTemplate(ctx: *zfinal.Context) !void {
    try service.updateTemplate(ctx);
}

pub fn deleteTemplate(ctx: *zfinal.Context) !void {
    try service.deleteTemplate(ctx);
}
