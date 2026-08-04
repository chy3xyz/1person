//! Referral module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn createCode(ctx: *zfinal.Context) !void {
    try service.createCode(ctx);
}

pub fn listCodes(ctx: *zfinal.Context) !void {
    try service.listCodes(ctx);
}

pub fn getCode(ctx: *zfinal.Context) !void {
    try service.getCode(ctx);
}

pub fn deleteCode(ctx: *zfinal.Context) !void {
    try service.deleteCode(ctx);
}

pub fn trackReferral(ctx: *zfinal.Context) !void {
    try service.trackReferral(ctx);
}

pub fn activateReferral(ctx: *zfinal.Context) !void {
    try service.activateReferral(ctx);
}

pub fn getReferralTree(ctx: *zfinal.Context) !void {
    try service.getReferralTree(ctx);
}

pub fn listRecords(ctx: *zfinal.Context) !void {
    try service.listRecords(ctx);
}
