//! Inbox module — thin HTTP delegates.
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

pub fn listInbox(ctx: *zfinal.Context) !void {
    try service.listInbox(ctx);
}

pub fn markInboxRead(ctx: *zfinal.Context) !void {
    try service.markInboxRead(ctx);
}

pub fn archiveInboxItem(ctx: *zfinal.Context) !void {
    try service.archiveInboxItem(ctx);
}

pub fn countUnreadInbox(ctx: *zfinal.Context) !void {
    try service.countUnreadInbox(ctx);
}

pub fn markAllInboxRead(ctx: *zfinal.Context) !void {
    try service.markAllInboxRead(ctx);
}

pub fn archiveAllInbox(ctx: *zfinal.Context) !void {
    try service.archiveAllInbox(ctx);
}

pub fn archiveAllReadInbox(ctx: *zfinal.Context) !void {
    try service.archiveAllReadInbox(ctx);
}

pub fn archiveCompletedInbox(ctx: *zfinal.Context) !void {
    try service.archiveCompletedInbox(ctx);
}

pub fn listInboxSince(ctx: *zfinal.Context) !void {
    try service.listInboxSince(ctx);
}

pub fn purgeInboxPair(ctx: *zfinal.Context) !void {
    try service.purgeInboxPair(ctx);
}

pub fn exportInboxEvents(ctx: *zfinal.Context) !void {
    try service.exportInboxEvents(ctx);
}
