//! Token economy module — data layer.
//!
//! Defines TokenConfig (a per-workspace token/points definition),
//! TokenBalance (per-user, per-workspace balance), and TokenTransaction
//! (earn / spend / transfer records). All persistence is through the
//! in-memory service; DB escape-hatch helpers can be added later.

const std = @import("std");

/// A named token/points configuration for a workspace.
pub const TokenConfig = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    total_supply: f64,
    created_at: []const u8,
};

/// Per-user, per-workspace token balance.
pub const TokenBalance = struct {
    user_id: []const u8,
    workspace_id: []const u8,
    balance: f64,
    updated_at: []const u8,
};

/// A single token transaction — earn, spend, or transfer.
pub const TokenTransaction = struct {
    id: []const u8,
    from_user_id: ?[]const u8,
    to_user_id: ?[]const u8,
    amount: f64,
    reason: []const u8,
    type: []const u8, // "earn" | "spend" | "transfer"
    created_at: []const u8,
};

/// JSON request for creating a token config.
pub const CreateConfigRequest = struct {
    name: []const u8,
    total_supply: ?f64 = null,
};

/// JSON request for updating a token config.
pub const UpdateConfigRequest = struct {
    name: ?[]const u8 = null,
    total_supply: ?f64 = null,
};

/// JSON request for earning tokens.
pub const EarnTokensRequest = struct {
    user_id: []const u8,
    amount: f64,
    reason: []const u8,
};

/// JSON request for spending tokens.
pub const SpendTokensRequest = struct {
    user_id: []const u8,
    amount: f64,
    reason: []const u8,
};

/// JSON request for transferring tokens between users.
pub const TransferTokensRequest = struct {
    from_user_id: []const u8,
    to_user_id: []const u8,
    amount: f64,
    reason: ?[]const u8 = null,
};

/// JSON query parameter for fetching a user's balance.
pub const BalanceQuery = struct {
    user_id: []const u8,
};

/// JSON query parameter for listing a user's transactions.
pub const TransactionsQuery = struct {
    user_id: []const u8,
};

/// Validate that the type string is one of the allowed values.
pub fn isValidTransactionType(t: []const u8) bool {
    return std.mem.eql(u8, t, "earn") or
        std.mem.eql(u8, t, "spend") or
        std.mem.eql(u8, t, "transfer");
}
