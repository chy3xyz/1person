//! Wallet module — data layer.
//!
//! Wallet tracks a user's fiat and reward balances within a workspace.
//! Transactions record every monetary movement (deposit, withdraw,
//! reward) with amounts and status.

const std = @import("std");

// ──────────────────────────────────────────────────────────────────────
// in-memory row types
// ──────────────────────────────────────────────────────────────────────

pub const Wallet = struct {
    id: []const u8,
    user_id: []const u8,
    workspace_id: []const u8,
    balance_fiat: f64,
    balance_reward: f64,
};

pub const Transaction = struct {
    id: []const u8,
    wallet_id: []const u8,
    amount: f64,
    type: []const u8, // "deposit" | "withdraw" | "reward"
    status: []const u8, // "pending" | "completed" | "failed"
    created_at: []const u8,
};

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

pub const AmountRequest = struct {
    amount: f64,
};
