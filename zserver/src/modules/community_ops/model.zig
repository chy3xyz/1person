//! Community ops module — data layer.
//!
//! CommunityGroup represents a named community within a workspace with a
//! member count. Announcement represents a message sent to a group that
//! can be scheduled for future publishing.

const std = @import("std");

/// A community group scoped to a workspace.
pub const CommunityGroup = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    member_count: u32,
};

/// An announcement posted to a community group.
pub const Announcement = struct {
    id: []const u8,
    group_id: []const u8,
    content: []const u8,
    scheduled_at: ?[]const u8,
    published_at: ?[]const u8,
};

/// JSON request shape for creating a group.
pub const CreateGroupRequest = struct {
    name: []const u8,
};

/// JSON request shape for creating an announcement.
pub const CreateAnnouncementRequest = struct {
    content: []const u8,
    scheduled_at: ?[]const u8 = null,
};

/// JSON response shape for the daily digest.
pub const DailyDigestResponse = struct {
    group_id: []const u8,
    member_count: u32,
    recent_activity: []const []const u8,
};
