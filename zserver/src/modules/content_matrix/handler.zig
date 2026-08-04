//! Content-matrix module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listPlatforms(ctx: *zfinal.Context) !void {
    try service.listPlatforms(ctx);
}

pub fn createPlatform(ctx: *zfinal.Context) !void {
    try service.createPlatform(ctx);
}

pub fn getPlatform(ctx: *zfinal.Context) !void {
    try service.getPlatform(ctx);
}

pub fn updatePlatform(ctx: *zfinal.Context) !void {
    try service.updatePlatform(ctx);
}

pub fn deletePlatform(ctx: *zfinal.Context) !void {
    try service.deletePlatform(ctx);
}

pub fn distributeContent(ctx: *zfinal.Context) !void {
    try service.distributeContent(ctx);
}

pub fn listResults(ctx: *zfinal.Context) !void {
    try service.listResults(ctx);
}

pub fn getResult(ctx: *zfinal.Context) !void {
    try service.getResult(ctx);
}
