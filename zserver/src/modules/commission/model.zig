//! Commission module — data layer.
//!
//! CommissionRule defines a split/commission rule with an ordered array of
//! levels. CommissionRecord captures one specific commission payout derived
//! from a transaction and linked to an upline chain position.

const std = @import("std");

/// CommissionRate for one level of the split chain.
pub const CommissionLevel = struct {
    depth: u32,
    rate: f64,
    role: ?[]const u8 = null,
};

/// A named commission rule that applies to a workspace.
pub const CommissionRule = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    levels: []const CommissionLevel,
    created_at: []const u8,
};

/// A single commission payout record generated from a transaction.
pub const CommissionRecord = struct {
    id: []const u8,
    transaction_id: []const u8,
    from_user_id: []const u8,
    to_user_id: []const u8,
    amount: f64,
    rate: f64,
    level: u32,
    status: []const u8, // "pending" | "settled"
    created_at: []const u8,
    settled_at: ?[]const u8 = null,
};

/// JSON request shape for creating a commission rule.
pub const CreateRuleRequest = struct {
    name: []const u8,
    levels: []const CommissionLevel,
};

/// JSON request shape for updating a commission rule.
pub const UpdateRuleRequest = struct {
    name: ?[]const u8 = null,
    levels: ?[]const CommissionLevel = null,
};

/// JSON request shape for calculating commissions.
pub const CalculateRequest = struct {
    rule_id: []const u8,
    transaction_id: []const u8,
    amount: f64,
    from_user_id: []const u8,
    upline_chain: []const []const u8,
};

/// JSON request shape for settling commission records.
pub const SettleRequest = struct {
    record_ids: []const []const u8,
};

/// Validate that levels are non-empty and rates are in (0, 1].
pub fn validateLevels(levels: []const CommissionLevel) bool {
    if (levels.len == 0) return false;
    for (levels) |l| {
        if (l.rate <= 0 or l.rate > 1) return false;
        if (l.depth == 0) return false;
    }
    return true;
}
