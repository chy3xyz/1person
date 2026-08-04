//! Cloud runtime module — wire types and in-memory row shape.
//!
//! Mirrors the `cloud_runtime_node` table in the Go server's
//! migration 121. The no-DB path keeps an in-memory map of
//! `CloudNodeEntry` keyed by node id; the DB path is a stub for
//! now.

const std = @import("std");

/// In-memory row for a single cloud node.
pub const CloudNodeEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    region: []const u8,
    size: []const u8,
    /// Lifecycle state. One of:
    /// `provisioning | running | stopped | rebooting | terminated`.
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    last_action_at: []const u8,
};

/// Wire DTO returned to the client.
pub const CloudNodeResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    region: []const u8,
    size: []const u8,
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    last_action_at: []const u8,
};

pub fn cloudNodeResponseFromEntry(entry: CloudNodeEntry) CloudNodeResponse {
    return .{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .region = entry.region,
        .size = entry.size,
        .status = entry.status,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
        .last_action_at = entry.last_action_at,
    };
}

/// `POST /api/cloud-runtime/nodes` body — provision a new node.
pub const CreateNodeRequest = struct {
    name: []const u8,
    region: []const u8 = "us-east-1",
    size: []const u8 = "small",
};

/// `POST /api/cloud-runtime/nodes/:id/exec` body.
pub const ExecRequest = struct {
    command: []const u8 = "",
    args: []const []const u8 = &[_][]const u8{},
};

/// Response for `/exec` (no-DB path returns a stub `output`).
pub const ExecResponse = struct {
    output: []const u8,
    exit_code: i32,
};

/// Response for `/status` (the most common poll).
pub const NodeStatusResponse = struct {
    id: []const u8,
    status: []const u8,
    last_action_at: []const u8,
};
