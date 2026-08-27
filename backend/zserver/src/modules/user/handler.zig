//! User module — thin HTTP delegates.
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

pub fn getMe(ctx: *zfinal.Context) !void {
    try service.getMe(ctx);
}

pub fn meMarker(ctx: *zfinal.Context) !void {
    try service.meMarker(ctx);
}

pub fn updateMe(ctx: *zfinal.Context) !void {
    try service.updateMe(ctx);
}

pub fn patchOnboarding(ctx: *zfinal.Context) !void {
    try service.patchOnboarding(ctx);
}

pub fn completeOnboarding(ctx: *zfinal.Context) !void {
    try service.completeOnboarding(ctx);
}

pub fn cloudWaitlist(ctx: *zfinal.Context) !void {
    try service.cloudWaitlist(ctx);
}

pub fn runtimeBootstrap(ctx: *zfinal.Context) !void {
    try service.runtimeBootstrap(ctx);
}

pub fn noRuntimeBootstrap(ctx: *zfinal.Context) !void {
    try service.noRuntimeBootstrap(ctx);
}

pub fn createCliToken(ctx: *zfinal.Context) !void {
    try service.createCliToken(ctx);
}

pub fn submitFeedback(ctx: *zfinal.Context) !void {
    try service.submitFeedback(ctx);
}
