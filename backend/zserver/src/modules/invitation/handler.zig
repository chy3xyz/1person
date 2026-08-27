//! Invitation module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listMyInvitations(ctx: *zfinal.Context) !void {
    try service.listMyInvitations(ctx);
}

pub fn getMyInvitation(ctx: *zfinal.Context) !void {
    try service.getMyInvitation(ctx);
}

pub fn acceptInvitation(ctx: *zfinal.Context) !void {
    try service.acceptInvitation(ctx);
}

pub fn declineInvitation(ctx: *zfinal.Context) !void {
    try service.declineInvitation(ctx);
}
