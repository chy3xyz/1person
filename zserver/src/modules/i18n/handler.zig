//! I18n module — thin HTTP delegates.
//!
//! All real logic lives in service.zig and model.zig. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn getTranslations(ctx: *zfinal.Context) !void {
    try service.getTranslations(ctx);
}

pub fn setTranslation(ctx: *zfinal.Context) !void {
    try service.setTranslation(ctx);
}

pub fn listLocales(ctx: *zfinal.Context) !void {
    try service.listLocales(ctx);
}
