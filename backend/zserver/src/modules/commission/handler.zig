//! Commission module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listRules(ctx: *zfinal.Context) !void {
    try service.listRules(ctx);
}

pub fn createRule(ctx: *zfinal.Context) !void {
    try service.createRule(ctx);
}

pub fn getRule(ctx: *zfinal.Context) !void {
    try service.getRule(ctx);
}

pub fn updateRule(ctx: *zfinal.Context) !void {
    try service.updateRule(ctx);
}

pub fn deleteRule(ctx: *zfinal.Context) !void {
    try service.deleteRule(ctx);
}

pub fn calculateCommission(ctx: *zfinal.Context) !void {
    try service.calculateCommission(ctx);
}

pub fn settleCommissions(ctx: *zfinal.Context) !void {
    try service.settleCommissions(ctx);
}

pub fn listRecords(ctx: *zfinal.Context) !void {
    try service.listRecords(ctx);
}

pub fn getRecord(ctx: *zfinal.Context) !void {
    try service.getRecord(ctx);
}
