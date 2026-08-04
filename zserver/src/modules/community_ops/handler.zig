//! Community ops module — thin HTTP delegates.
//!
//! All logic lives in service.zig. This file is a 1-line passthrough
//! per route matching the zfinal examples/ruoyi-gen/ convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listGroups(ctx: *zfinal.Context) !void {
    try service.listGroups(ctx);
}

pub fn createGroup(ctx: *zfinal.Context) !void {
    try service.createGroup(ctx);
}

pub fn getGroup(ctx: *zfinal.Context) !void {
    try service.getGroup(ctx);
}

pub fn deleteGroup(ctx: *zfinal.Context) !void {
    try service.deleteGroup(ctx);
}

pub fn addMember(ctx: *zfinal.Context) !void {
    try service.addMember(ctx);
}

pub fn removeMember(ctx: *zfinal.Context) !void {
    try service.removeMember(ctx);
}

pub fn createAnnouncement(ctx: *zfinal.Context) !void {
    try service.createAnnouncement(ctx);
}

pub fn publishAnnouncement(ctx: *zfinal.Context) !void {
    try service.publishAnnouncement(ctx);
}

pub fn getDailyDigest(ctx: *zfinal.Context) !void {
    try service.getDailyDigest(ctx);
}
