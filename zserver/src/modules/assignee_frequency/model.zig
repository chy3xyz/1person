//! Assignee frequency module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs. `service.zig` wraps this with the business logic.
//! This module has no database access — the legacy handler returned an
//! empty array — so there are no SQL helpers here.

const std = @import("std");

/// Single row of the `assignee_frequency` response. Mirrors the Go
/// `AssigneeFrequencyEntry` (`frequency` is the count of times the
/// current user assigned work to that target).
pub const FrequencyEntry = struct {
    assignee_type: []const u8,
    assignee_id: []const u8,
    frequency: i64,
};