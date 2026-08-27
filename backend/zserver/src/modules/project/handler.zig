//! Project module — thin HTTP delegates.
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

pub fn listProjects(ctx: *zfinal.Context) !void {
    try service.listProjects(ctx);
}

pub fn getProject(ctx: *zfinal.Context) !void {
    try service.getProject(ctx);
}

pub fn createProject(ctx: *zfinal.Context) !void {
    try service.createProject(ctx);
}

pub fn updateProject(ctx: *zfinal.Context) !void {
    try service.updateProject(ctx);
}

pub fn deleteProject(ctx: *zfinal.Context) !void {
    try service.deleteProject(ctx);
}

pub fn listResources(ctx: *zfinal.Context) !void {
    try service.listResources(ctx);
}

pub fn createResource(ctx: *zfinal.Context) !void {
    try service.createResource(ctx);
}

pub fn updateResource(ctx: *zfinal.Context) !void {
    try service.updateResource(ctx);
}

pub fn deleteResource(ctx: *zfinal.Context) !void {
    try service.deleteResource(ctx);
}
