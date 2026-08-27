//! Notification module — data layer.
//!
//! NotificationTemplate defines a reusable notification template keyed by
//! channel. NotificationLog records one delivery attempt and its current
//! lifecycle status.

const std = @import("std");

/// Supported delivery channels.
pub const NotificationChannel = enum {
    email,
    sms,
    wechat,
    telegram,
    discord,
    push,
    in_app,

    pub fn asStr(self: NotificationChannel) []const u8 {
        return switch (self) {
            .email => "email",
            .sms => "sms",
            .wechat => "wechat",
            .telegram => "telegram",
            .discord => "discord",
            .push => "push",
            .in_app => "in_app",
        };
    }

    pub fn fromStr(s: []const u8) ?NotificationChannel {
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "sms")) return .sms;
        if (std.mem.eql(u8, s, "wechat")) return .wechat;
        if (std.mem.eql(u8, s, "telegram")) return .telegram;
        if (std.mem.eql(u8, s, "discord")) return .discord;
        if (std.mem.eql(u8, s, "push")) return .push;
        if (std.mem.eql(u8, s, "in_app")) return .in_app;
        return null;
    }
};

/// Delivery lifecycle status.
pub const NotificationStatus = enum {
    queued,
    sent,
    failed,
    opened,

    pub fn asStr(self: NotificationStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .sent => "sent",
            .failed => "failed",
            .opened => "opened",
        };
    }
};

/// A reusable notification template scoped to a workspace.
pub const NotificationTemplate = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    channel: []const u8, // "email"|"sms"|"wechat"|"telegram"|"discord"|"push"|"in_app"
    subject_template: []const u8,
    body_template: []const u8,
};

/// A single notification delivery log entry.
pub const NotificationLog = struct {
    id: []const u8,
    template_id: []const u8,
    user_id: []const u8,
    channel: []const u8,
    status: []const u8, // "queued"|"sent"|"failed"|"opened"
    created_at: []const u8,
};

/// JSON request shape for creating a notification template.
pub const CreateTemplateRequest = struct {
    name: []const u8,
    channel: []const u8,
    subject_template: []const u8,
    body_template: []const u8,
};

/// JSON request shape for updating a notification template.
pub const UpdateTemplateRequest = struct {
    name: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    subject_template: ?[]const u8 = null,
    body_template: ?[]const u8 = null,
};


