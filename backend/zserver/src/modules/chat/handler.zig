//! Chat module — thin HTTP delegates.
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

pub fn listChatSessions(ctx: *zfinal.Context) !void {
    try service.listChatSessions(ctx);
}

pub fn createChatSession(ctx: *zfinal.Context) !void {
    try service.createChatSession(ctx);
}

pub fn getChatSession(ctx: *zfinal.Context) !void {
    try service.getChatSession(ctx);
}

pub fn updateChatSession(ctx: *zfinal.Context) !void {
    try service.updateChatSession(ctx);
}

pub fn deleteChatSession(ctx: *zfinal.Context) !void {
    try service.deleteChatSession(ctx);
}

pub fn sendChatMessage(ctx: *zfinal.Context) !void {
    try service.sendChatMessage(ctx);
}

pub fn listChatMessages(ctx: *zfinal.Context) !void {
    try service.listChatMessages(ctx);
}

pub fn listChatMessagesPage(ctx: *zfinal.Context) !void {
    try service.listChatMessagesPage(ctx);
}

pub fn getPendingChatTask(ctx: *zfinal.Context) !void {
    try service.getPendingChatTask(ctx);
}

pub fn markChatSessionRead(ctx: *zfinal.Context) !void {
    try service.markChatSessionRead(ctx);
}

pub fn listPendingChatTasks(ctx: *zfinal.Context) !void {
    try service.listPendingChatTasks(ctx);
}
