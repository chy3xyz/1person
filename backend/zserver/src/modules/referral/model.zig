//! Referral module — data layer.
//!
//! ReferralCode is a single-use invitation code tied to a workspace;
//! ReferralRecord captures each referral event with a lifecycle.
//! Statuses: registered → activated → paid.

const std = @import("std");

/// A referral code owned by a user belonging to a workspace.
pub const ReferralCode = struct {
    code: []const u8,
    user_id: []const u8,
    workspace_id: []const u8,
};

/// A referral event: who referred whom, with what code, and its status.
pub const ReferralRecord = struct {
    id: []const u8,
    code: []const u8,
    referrer_user_id: []const u8,
    referee_user_id: []const u8,
    status: []const u8, // "registered" | "activated" | "paid"
    rewarded_at: []const u8,
};

/// JSON request shape for creating a referral code.
pub const CreateCodeRequest = struct {
    code: []const u8,
};

/// JSON request shape for tracking a referral.
pub const TrackReferralRequest = struct {
    code: []const u8,
    referee_user_id: []const u8,
};

/// JSON request shape for activating a referral.
pub const ActivateReferralRequest = struct {
    referee_user_id: []const u8,
};
