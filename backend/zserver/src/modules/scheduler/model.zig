//! Scheduler module — data layer.
//!
//! ScheduledTask represents a task that can be scheduled to run at a
//! specific timestamp. The service layer simulates execution by
//! advancing status: pending → running → done (or failed on retries).

const std = @import("std");

/// A scheduled task with execution timestamp, status tracking, and retry support.
pub const ScheduledTask = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    payload_json: []const u8,
    run_at_ts: i64, // unix timestamp (seconds)
    status: []const u8, // "pending" | "running" | "done" | "failed" | "cancelled"
    retries: u32,
    max_retries: u32,
    depends_on: []const []const u8, // IDs of tasks that must complete first
    created_at: []const u8,
};

/// JSON request shape for creating a scheduled task.
pub const ScheduleTaskRequest = struct {
    name: []const u8,
    payload_json: []const u8 = "",
    run_at_ts: i64 = 0,
    max_retries: u32 = 3,
    depends_on: []const []const u8 = &[_][]const u8{},
};
