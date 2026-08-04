//! Squad module — thin HTTP delegates.
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

pub fn listSquads(ctx: *zfinal.Context) !void {
    try service.listSquads(ctx);
}

pub fn getSquad(ctx: *zfinal.Context) !void {
    try service.getSquad(ctx);
}

pub fn createSquad(ctx: *zfinal.Context) !void {
    try service.createSquad(ctx);
}

pub fn updateSquad(ctx: *zfinal.Context) !void {
    try service.updateSquad(ctx);
}

pub fn deleteSquad(ctx: *zfinal.Context) !void {
    try service.deleteSquad(ctx);
}

pub fn listMembers(ctx: *zfinal.Context) !void {
    try service.listMembers(ctx);
}

pub fn addMember(ctx: *zfinal.Context) !void {
    try service.addMember(ctx);
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    try service.removeMember(ctx);
}

pub fn memberStatus(ctx: *zfinal.Context) !void {
    try service.memberStatus(ctx);
}