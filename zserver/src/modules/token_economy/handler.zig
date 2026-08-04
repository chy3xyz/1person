//! Token economy module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn init(_: *const Config) void {}

// ── Config CRUD ─────────────────────────────────────────────────

pub fn listConfigs(ctx: *zfinal.Context) !void {
    try service.listConfigs(ctx);
}

pub fn createConfig(ctx: *zfinal.Context) !void {
    try service.createConfig(ctx);
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    try service.getConfig(ctx);
}

pub fn updateConfig(ctx: *zfinal.Context) !void {
    try service.updateConfig(ctx);
}

pub fn deleteConfig(ctx: *zfinal.Context) !void {
    try service.deleteConfig(ctx);
}

// ── Token operations ────────────────────────────────────────────

pub fn earnTokens(ctx: *zfinal.Context) !void {
    try service.earnTokens(ctx);
}

pub fn spendTokens(ctx: *zfinal.Context) !void {
    try service.spendTokens(ctx);
}

pub fn transferTokens(ctx: *zfinal.Context) !void {
    try service.transferTokens(ctx);
}

pub fn getBalance(ctx: *zfinal.Context) !void {
    try service.getBalance(ctx);
}

pub fn listTransactions(ctx: *zfinal.Context) !void {
    try service.listTransactions(ctx);
}
