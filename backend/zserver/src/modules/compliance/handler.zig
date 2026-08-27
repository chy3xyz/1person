//! Compliance module — thin HTTP delegates.

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

pub fn runAudit(ctx: *zfinal.Context) !void {
    try service.runAudit(ctx);
}

pub fn listAuditLogs(ctx: *zfinal.Context) !void {
    try service.listAuditLogs(ctx);
}
