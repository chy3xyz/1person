//! Agent module — thin HTTP delegates.
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

pub fn listAgents(ctx: *zfinal.Context) !void {
    try service.listAgents(ctx);
}

pub fn getAgent(ctx: *zfinal.Context) !void {
    try service.getAgent(ctx);
}

pub fn createAgent(ctx: *zfinal.Context) !void {
    try service.createAgent(ctx);
}

pub fn updateAgent(ctx: *zfinal.Context) !void {
    try service.updateAgent(ctx);
}

pub fn archiveAgent(ctx: *zfinal.Context) !void {
    try service.archiveAgent(ctx);
}

pub fn restoreAgent(ctx: *zfinal.Context) !void {
    try service.restoreAgent(ctx);
}

pub fn cancelTasks(ctx: *zfinal.Context) !void {
    try service.cancelTasks(ctx);
}

pub fn listTasks(ctx: *zfinal.Context) !void {
    try service.listTasks(ctx);
}

pub fn getEnv(ctx: *zfinal.Context) !void {
    try service.getEnv(ctx);
}

pub fn setEnv(ctx: *zfinal.Context) !void {
    try service.setEnv(ctx);
}

pub fn listAgentSkills(ctx: *zfinal.Context) !void {
    try service.listAgentSkills(ctx);
}

pub fn setAgentSkills(ctx: *zfinal.Context) !void {
    try service.setAgentSkills(ctx);
}

pub fn addAgentSkills(ctx: *zfinal.Context) !void {
    try service.addAgentSkills(ctx);
}
