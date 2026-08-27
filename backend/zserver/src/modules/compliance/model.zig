//! Compliance module — data layer.
//!
//! AuditRule defines a compliance check rule (manual, auto, or scheduled).
//! AuditLog captures the result of a single audit execution.

const std = @import("std");

/// An audit/compliance rule that can be checked manually, automatically,
/// or on a cron schedule.
pub const AuditRule = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    /// "manual" | "auto" | "scheduled"
    check_type: []const u8,
    /// Required when check_type is "scheduled".
    cron_expression: ?[]const u8 = null,
    created_at: []const u8,
};

/// A single audit run result linked to a rule.
pub const AuditLog = struct {
    id: []const u8,
    rule_id: []const u8,
    workspace_id: []const u8,
    /// "pass" | "fail" | "pending"
    status: []const u8,
    details: []const u8,
    created_at: []const u8,
};

/// JSON request shape for creating an audit rule.
pub const CreateRuleRequest = struct {
    name: []const u8,
    description: []const u8,
    /// "manual" | "auto" | "scheduled"
    check_type: []const u8,
    cron_expression: ?[]const u8 = null,
};

/// JSON request shape for updating an audit rule.
pub const UpdateRuleRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    check_type: ?[]const u8 = null,
    cron_expression: ?[]const u8 = null,
};

/// JSON request shape for running an audit.
pub const RunAuditRequest = struct {
    rule_id: []const u8,
};

/// Validate that check_type is one of the allowed values.
pub fn validateCheckType(t: []const u8) bool {
    return std.mem.eql(u8, t, "manual") or
        std.mem.eql(u8, t, "auto") or
        std.mem.eql(u8, t, "scheduled");
}
