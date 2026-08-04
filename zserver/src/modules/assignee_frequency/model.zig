//! Assignee frequency module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs. `service.zig` wraps this with the business logic.
//! This module has no database access — the legacy handler returned an
//! empty array — so there are no SQL helpers here.

const std = @import("std");

/// Single row of the `assignee_frequency` response. The legacy
/// handler emitted zero rows; the shape is preserved so future code
/// can populate it without an API change.
pub const FrequencyEntry = struct {
    assignee_type: []const u8,
    assignee_id: []const u8,
    count: i32,
};