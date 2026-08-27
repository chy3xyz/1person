//! Skill module — thin HTTP delegates.
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

pub fn listSkills(ctx: *zfinal.Context) !void {
    try service.listSkills(ctx);
}

pub fn searchSkills(ctx: *zfinal.Context) !void {
    try service.searchSkills(ctx);
}

pub fn createSkill(ctx: *zfinal.Context) !void {
    try service.createSkill(ctx);
}

pub fn getSkill(ctx: *zfinal.Context) !void {
    try service.getSkill(ctx);
}

pub fn updateSkill(ctx: *zfinal.Context) !void {
    try service.updateSkill(ctx);
}

pub fn deleteSkill(ctx: *zfinal.Context) !void {
    try service.deleteSkill(ctx);
}

pub fn importSkill(ctx: *zfinal.Context) !void {
    try service.importSkill(ctx);
}

pub fn listSkillFiles(ctx: *zfinal.Context) !void {
    try service.listSkillFiles(ctx);
}

pub fn upsertSkillFile(ctx: *zfinal.Context) !void {
    try service.upsertSkillFile(ctx);
}

pub fn deleteSkillFile(ctx: *zfinal.Context) !void {
    try service.deleteSkillFile(ctx);
}
