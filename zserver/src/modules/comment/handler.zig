//! Comment module — thin HTTP delegates.
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

pub fn listComments(ctx: *zfinal.Context) !void {
    try service.listComments(ctx);
}

pub fn getComment(ctx: *zfinal.Context) !void {
    try service.getComment(ctx);
}

pub fn createComment(ctx: *zfinal.Context) !void {
    try service.createComment(ctx);
}

pub fn updateComment(ctx: *zfinal.Context) !void {
    try service.updateComment(ctx);
}

pub fn deleteComment(ctx: *zfinal.Context) !void {
    try service.deleteComment(ctx);
}

pub fn resolveComment(ctx: *zfinal.Context) !void {
    try service.resolveComment(ctx);
}

pub fn unresolveComment(ctx: *zfinal.Context) !void {
    try service.unresolveComment(ctx);
}

pub fn previewCommentTriggers(ctx: *zfinal.Context) !void {
    try service.previewCommentTriggers(ctx);
}

pub fn addReaction(ctx: *zfinal.Context) !void {
    try service.addReaction(ctx);
}

pub fn removeReaction(ctx: *zfinal.Context) !void {
    try service.removeReaction(ctx);
}
