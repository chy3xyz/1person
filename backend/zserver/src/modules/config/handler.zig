//! Config module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.
//!
//! The config module keeps the legacy `setConfig(cfg)` name (instead
//! of `init`) because `src/router.zig::registerAll` still calls it by
//! that name when wiring up the process-wide `Config` pointer.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn setConfig(cfg: *const Config) void {
    service.init(cfg);
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    try service.getConfig(ctx);
}
