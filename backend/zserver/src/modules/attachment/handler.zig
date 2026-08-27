//! Attachment module — thin HTTP delegates.
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

pub fn uploadFile(ctx: *zfinal.Context) !void {
    try service.uploadFile(ctx);
}

pub fn downloadAttachment(ctx: *zfinal.Context) !void {
    try service.downloadAttachment(ctx);
}

pub fn getAttachmentByID(ctx: *zfinal.Context) !void {
    try service.getAttachmentByID(ctx);
}

pub fn getAttachmentContent(ctx: *zfinal.Context) !void {
    try service.getAttachmentContent(ctx);
}

pub fn deleteAttachment(ctx: *zfinal.Context) !void {
    try service.deleteAttachment(ctx);
}

pub fn serveUploads(ctx: *zfinal.Context) !void {
    try service.serveUploads(ctx);
}

pub fn listAttachments(ctx: *zfinal.Context) !void {
    try service.listAttachments(ctx);
}
