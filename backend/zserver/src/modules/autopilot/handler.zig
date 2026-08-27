//! Autopilot module — thin HTTP delegates.
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

pub fn listAutopilots(ctx: *zfinal.Context) !void {
    try service.listAutopilots(ctx);
}

pub fn getAutopilot(ctx: *zfinal.Context) !void {
    try service.getAutopilot(ctx);
}

pub fn createAutopilot(ctx: *zfinal.Context) !void {
    try service.createAutopilot(ctx);
}

pub fn updateAutopilot(ctx: *zfinal.Context) !void {
    try service.updateAutopilot(ctx);
}

pub fn deleteAutopilot(ctx: *zfinal.Context) !void {
    try service.deleteAutopilot(ctx);
}

pub fn triggerAutopilot(ctx: *zfinal.Context) !void {
    try service.triggerAutopilot(ctx);
}

pub fn listTriggers(ctx: *zfinal.Context) !void {
    try service.listTriggers(ctx);
}

pub fn createTrigger(ctx: *zfinal.Context) !void {
    try service.createTrigger(ctx);
}

pub fn updateTrigger(ctx: *zfinal.Context) !void {
    try service.updateTrigger(ctx);
}

pub fn deleteTrigger(ctx: *zfinal.Context) !void {
    try service.deleteTrigger(ctx);
}

pub fn setSigningSecret(ctx: *zfinal.Context) !void {
    try service.setSigningSecret(ctx);
}

pub fn listRuns(ctx: *zfinal.Context) !void {
    try service.listRuns(ctx);
}

pub fn getRun(ctx: *zfinal.Context) !void {
    try service.getRun(ctx);
}

pub fn listDeliveries(ctx: *zfinal.Context) !void {
    try service.listDeliveries(ctx);
}

pub fn getDelivery(ctx: *zfinal.Context) !void {
    try service.getDelivery(ctx);
}

pub fn replayDelivery(ctx: *zfinal.Context) !void {
    try service.replayDelivery(ctx);
}

pub fn rotateWebhookToken(ctx: *zfinal.Context) !void {
    try service.rotateWebhookToken(ctx);
}
