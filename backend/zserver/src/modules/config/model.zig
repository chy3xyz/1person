//! Config module — data layer.
//!
//! No DB and no in-memory store: the module reads a process-wide
//! `*const Config` set at startup and projects a subset of it to
//! clients. The `PublicConfig` struct here is the JSON shape the API
//! returns; `service.zig` populates it from the global `Config`.

const std = @import("std");

/// Subset of `Config` returned by `GET /api/config`. Kept as a struct
/// (rather than serialised inline) so `service.zig` can construct it
/// once and `renderJson` can stream it as a JSON object. Optional
/// fields mirror the optional `?[]const u8` types on `Config.app` so
/// the struct can be populated directly without coercion — `null`
/// values are serialised as JSON `null` by `std.json.Stringify`.
pub const PublicConfig = struct {
    allow_signup: bool,
    google_client_id: []const u8,
    /// Origin used to build durable attachment links persisted into Markdown
    /// bodies (see `attachment.buildMarkdownURL`). Empty when
    /// `ONEPERSON_PUBLIC_URL` is unset, in which case those links stay
    /// server-relative. Clients use this only to recognise links that belong
    /// to THIS deployment — another instance may serve the same path shape
    /// with unrelated attachment ids.
    attachment_public_url: ?[]const u8,
    workspace_creation_disabled: bool,
    daemon_server_url: ?[]const u8,
    daemon_app_url: ?[]const u8,
    posthog_key: ?[]const u8,
    posthog_host: ?[]const u8,
    analytics_environment: []const u8,
};
