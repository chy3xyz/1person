//! Cloud runtime module — HTTP handler passthroughs.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listCloudNodes(ctx: *zfinal.Context) !void {
    try service.listCloudNodes(ctx);
}

pub fn createCloudNode(ctx: *zfinal.Context) !void {
    try service.createCloudNode(ctx);
}

pub fn deleteCloudNode(ctx: *zfinal.Context) !void {
    try service.deleteCloudNode(ctx);
}

pub fn startCloudNode(ctx: *zfinal.Context) !void {
    try service.startCloudNode(ctx);
}

pub fn stopCloudNode(ctx: *zfinal.Context) !void {
    try service.stopCloudNode(ctx);
}

pub fn rebootCloudNode(ctx: *zfinal.Context) !void {
    try service.rebootCloudNode(ctx);
}

pub fn execOnCloudNode(ctx: *zfinal.Context) !void {
    try service.execOnCloudNode(ctx);
}

pub fn getCloudNodeStatus(ctx: *zfinal.Context) !void {
    try service.getCloudNodeStatus(ctx);
}
