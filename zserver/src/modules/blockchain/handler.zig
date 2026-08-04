//! Blockchain module — thin HTTP delegates.
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

// Chain configs
pub fn listConfigs(ctx: *zfinal.Context) !void { try service.listConfigs(ctx); }
pub fn createConfig(ctx: *zfinal.Context) !void { try service.createConfig(ctx); }
pub fn getConfig(ctx: *zfinal.Context) !void { try service.getConfig(ctx); }
pub fn updateConfig(ctx: *zfinal.Context) !void { try service.updateConfig(ctx); }
pub fn deleteConfig(ctx: *zfinal.Context) !void { try service.deleteConfig(ctx); }

// Wallets
pub fn listWallets(ctx: *zfinal.Context) !void { try service.listWallets(ctx); }
pub fn createWallet(ctx: *zfinal.Context) !void { try service.createWallet(ctx); }
pub fn getWallet(ctx: *zfinal.Context) !void { try service.getWallet(ctx); }
pub fn updateWallet(ctx: *zfinal.Context) !void { try service.updateWallet(ctx); }
pub fn deleteWallet(ctx: *zfinal.Context) !void { try service.deleteWallet(ctx); }

// Transactions
pub fn sendTransaction(ctx: *zfinal.Context) !void { try service.sendTransaction(ctx); }
pub fn listTransactions(ctx: *zfinal.Context) !void { try service.listTransactions(ctx); }
pub fn getTransaction(ctx: *zfinal.Context) !void { try service.getTransaction(ctx); }

// Balance
pub fn getBalance(ctx: *zfinal.Context) !void { try service.getBalance(ctx); }
