//! Scheduler module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn scheduleTask(ctx: *zfinal.Context) !void {
    try service.scheduleTask(ctx);
}

pub fn getTask(ctx: *zfinal.Context) !void {
    try service.getTask(ctx);
}

pub fn listTasks(ctx: *zfinal.Context) !void {
    try service.listTasks(ctx);
}

pub fn executeNow(ctx: *zfinal.Context) !void {
    try service.executeNow(ctx);
}

pub fn cancelTask(ctx: *zfinal.Context) !void {
    try service.cancelTask(ctx);
}

pub fn retryTask(ctx: *zfinal.Context) !void {
    try service.retryTask(ctx);
}
