//! Pipeline orchestration engine — wire types and in-memory store.
//!
//! A Pipeline is a DAG of Phases. Each Phase has an assigned agent,
//! optional dependencies, timeout, retry count, and an approval gate.
//! A PipelineRun tracks one execution with per-phase status.

const std = @import("std");

/// Persisted pipeline configuration (reusable template).
/// In no-DB mode, the full phase list is stored in a companion map
/// (`mem_phases_bytes`) serialised as JSON bytes — this avoids the
/// Zig type-system complexity of deep-copying nested struct slices.
pub const PipelineConfig = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    phase_count: usize = 0,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const PipelineConfigDetail = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
    phases: []const PhaseConfig,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const PhaseConfig = struct {
    id: []const u8,
    name: []const u8,
    agent: []const u8, // agent name for claim
    depends_on: []const []const u8, // phase IDs that must complete first
    timeout_seconds: u64 = 3600,
    max_retries: u32 = 3,
    approval_gate: bool = false,
    artifact_pattern: []const u8 = "",
};

/// A single execution of a pipeline.
pub const PipelineRun = struct {
    id: []const u8,
    pipeline_id: []const u8,
    workspace_id: []const u8,
    status: []const u8, // pending|running|blocked|done|failed
    current_phase_id: []const u8,
    phases: std.ArrayList(PhaseRun),
    created_at: []const u8,
    updated_at: []const u8,
};

pub const PhaseRun = struct {
    phase_id: []const u8,
    name: []const u8,
    status: []const u8, // pending|waiting_deps|running|awaiting_approval|done|failed
    task_ids: std.ArrayList([]const u8),
    retries: u32 = 0,
};

pub const CreatePipelineRequest = struct {
    name: []const u8,
    description: []const u8 = "",
    phases: []const PhaseConfig,
};

pub const UpdatePipelineRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    phases: ?[]const PhaseConfig = null,
};

pub const PipelineConfigResponse = PipelineConfig;

pub const PipelineRunResponse = struct {
    id: []const u8,
    pipeline_id: []const u8,
    status: []const u8,
    current_phase_id: []const u8,
    phases: []const PhaseRunResponse,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const PhaseRunResponse = struct {
    phase_id: []const u8,
    name: []const u8,
    status: []const u8,
    task_ids: []const []const u8,
    retries: u32,
};
