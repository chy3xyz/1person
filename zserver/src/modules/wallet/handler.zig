//! Wallet module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn createWallet(ctx: *zfinal.Context) !void {
    try service.createWallet(ctx);
}

pub fn getWallet(ctx: *zfinal.Context) !void {
    try service.getWallet(ctx);
}

pub fn deposit(ctx: *zfinal.Context) !void {
    try service.deposit(ctx);
}

pub fn withdraw(ctx: *zfinal.Context) !void {
    try service.withdraw(ctx);
}

pub fn addReward(ctx: *zfinal.Context) !void {
    try service.addReward(ctx);
}

pub fn listTransactions(ctx: *zfinal.Context) !void {
    try service.listTransactions(ctx);
}
