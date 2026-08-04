//! Content-matrix module — data layer.
//!
//! PlatformConfig describes a target platform (blog, twitter, linkedin, …).
//! DistributeRequest carries the original markdown + list of platform IDs.
//! DistributeResult captures the outcome for one platform after adaptation.

const std = @import("std");

/// A configured distribution target.
pub const PlatformConfig = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    adapter_type: []const u8,
    created_at: []const u8,
};

/// Inbound request to distribute original content to a set of platforms.
pub const DistributeRequest = struct {
    original_content: []const u8,
    platforms: []const []const u8,
};

/// Outcome record for one platform after a distribution run.
pub const DistributeResult = struct {
    id: []const u8,
    platform: []const u8,
    platform_name: []const u8,
    content_url: []const u8,
    status: []const u8, // "ok" | "error"
    created_at: []const u8,
};

/// JSON shape for creating a platform.
pub const CreatePlatformRequest = struct {
    name: []const u8,
    adapter_type: []const u8,
};

/// JSON shape for updating a platform.
pub const UpdatePlatformRequest = struct {
    name: ?[]const u8 = null,
    adapter_type: ?[]const u8 = null,
};

/// Validate that platform fields are non-empty.
pub fn validatePlatform(name: []const u8, adapter_type: []const u8) bool {
    return name.len > 0 and adapter_type.len > 0;
}
