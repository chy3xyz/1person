//! Blockchain module — data layer.
//!
//! In-memory only: no DB persistence. ChainConfigs, Wallets, and
//! Transactions are stored in `std.StringHashMap`s managed by
//! `service.zig`. This file holds the data structs and ID helpers.

const std = @import("std");
const zfinal = @import("zfinal");

/// An EVM-compatible chain configuration scoped to a workspace.
pub const ChainConfig = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    rpc_url: []const u8,
    chain_id: i64,
};

/// A wallet belonging to a workspace, optionally linked to a chain config.
pub const Wallet = struct {
    id: []const u8,
    workspace_id: []const u8,
    address: []const u8,
    private_key_encrypted: []const u8,
    chain: []const u8, // chain config id or empty
};

pub const TxStatus = enum {
    pending,
    confirmed,
    failed,
};

/// An on-chain transaction submitted from a wallet.
pub const Transaction = struct {
    id: []const u8,
    wallet_id: []const u8,
    tx_hash: []const u8,
    method: []const u8,
    params_json: []const u8,
    status: TxStatus,
    created_at: []const u8,
};

/// Request body for `POST /api/blockchain/configs`.
pub const CreateConfigRequest = struct {
    name: []const u8,
    rpc_url: []const u8,
    chain_id: i64,
};

/// Request body for `POST /api/blockchain/wallets`.
pub const CreateWalletRequest = struct {
    address: []const u8,
    private_key_encrypted: []const u8,
    chain: ?[]const u8 = null,
};

/// Request body for `POST /api/blockchain/transactions`.
pub const SendTxRequest = struct {
    wallet_id: []const u8,
    method: []const u8,
    params_json: []const u8,
};

/// Generate a 32-char hex id from a timestamp + seed.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

/// Generate a fake 66-char tx hash (0x + 64 hex chars).
pub fn generateTxHash(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [32]u8 = undefined;
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    var prng = std.Random.DefaultPrng.init(@intCast(ns));
    prng.random().bytes(&buf);
    const hex = try allocator.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (buf, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    const result = try allocator.alloc(u8, 66);
    result[0] = '0';
    result[1] = 'x';
    @memcpy(result[2..], hex);
    allocator.free(hex);
    return result;
}

/// Render the current Unix-epoch seconds as an RFC-3339 UTC string.
pub fn rfc3339(allocator: std.mem.Allocator, ts: i64) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sd = epoch.getDaySeconds();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        sd.getHoursIntoDay(), sd.getMinutesIntoHour(), sd.getSecondsIntoMinute(),
    });
}
