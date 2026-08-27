//! Runtime module — thin HTTP delegates.
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

pub fn listAgentRuntimes(ctx: *zfinal.Context) !void {
    try service.listAgentRuntimes(ctx);
}

pub fn updateAgentRuntime(ctx: *zfinal.Context) !void {
    try service.updateAgentRuntime(ctx);
}

pub fn deleteAgentRuntime(ctx: *zfinal.Context) !void {
    try service.deleteAgentRuntime(ctx);
}

pub fn archiveAgentsAndDeleteRuntime(ctx: *zfinal.Context) !void {
    try service.archiveAgentsAndDeleteRuntime(ctx);
}

pub fn getRuntimeUsage(ctx: *zfinal.Context) !void {
    try service.getRuntimeUsage(ctx);
}

pub fn getRuntimeUsageByAgent(ctx: *zfinal.Context) !void {
    try service.getRuntimeUsageByAgent(ctx);
}

pub fn getRuntimeUsageByHour(ctx: *zfinal.Context) !void {
    try service.getRuntimeUsageByHour(ctx);
}

pub fn getRuntimeTaskActivity(ctx: *zfinal.Context) !void {
    try service.getRuntimeTaskActivity(ctx);
}

pub fn initiateUpdate(ctx: *zfinal.Context) !void {
    try service.initiateUpdate(ctx);
}

pub fn getUpdate(ctx: *zfinal.Context) !void {
    try service.getUpdate(ctx);
}

pub fn initiateListModels(ctx: *zfinal.Context) !void {
    try service.initiateListModels(ctx);
}

pub fn getModelListRequest(ctx: *zfinal.Context) !void {
    try service.getModelListRequest(ctx);
}

pub fn initiateListLocalSkills(ctx: *zfinal.Context) !void {
    try service.initiateListLocalSkills(ctx);
}

pub fn getLocalSkillListRequest(ctx: *zfinal.Context) !void {
    try service.getLocalSkillListRequest(ctx);
}

pub fn initiateImportLocalSkill(ctx: *zfinal.Context) !void {
    try service.initiateImportLocalSkill(ctx);
}

pub fn getLocalSkillImportRequest(ctx: *zfinal.Context) !void {
    try service.getLocalSkillImportRequest(ctx);
}
