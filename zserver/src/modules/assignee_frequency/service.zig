//! Assignee frequency module — business logic.
//!
//! Exposes the single HTTP-facing operation: `getAssigneeFrequency`.
//! The `handler.zig` is a thin delegate; data shapes live in
//! `model.zig`. The legacy handler had no database access and
//! returned an empty array; the no-DB fallback is therefore the only
//! behaviour.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");

pub fn init(_: *const anyopaque) void {}

pub fn getAssigneeFrequency(ctx: *zfinal.Context) !void {
    try ctx.renderJson(&[_]model.FrequencyEntry{});
}