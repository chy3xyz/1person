//! Notification module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listTemplates(ctx: *zfinal.Context) !void {
    try service.listTemplates(ctx);
}

pub fn createTemplate(ctx: *zfinal.Context) !void {
    try service.createTemplate(ctx);
}

pub fn getTemplate(ctx: *zfinal.Context) !void {
    try service.getTemplate(ctx);
}

pub fn updateTemplate(ctx: *zfinal.Context) !void {
    try service.updateTemplate(ctx);
}

pub fn deleteTemplate(ctx: *zfinal.Context) !void {
    try service.deleteTemplate(ctx);
}

pub fn send(ctx: *zfinal.Context) !void {
    try service.send(ctx);
}

pub fn getLogs(ctx: *zfinal.Context) !void {
    try service.getLogs(ctx);
}

pub fn listChannels(ctx: *zfinal.Context) !void {
    try service.listChannels(ctx);
}
