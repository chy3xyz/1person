//! Config module — business logic.
//!
//! Owns the process-wide `g_cfg` pointer set once at startup by
//! `handler.setConfig`. The single HTTP-facing operation is
//! `getConfig`, which projects the safe-to-expose subset of fields
//! from `Config` into a `model.PublicConfig` and renders it as JSON.
//! `handler.zig` is a thin delegate.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const model = @import("model.zig");

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    const cfg = g_cfg orelse {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "config_not_loaded" });
        return;
    };

    try ctx.renderJson(model.PublicConfig{
        .allow_signup = cfg.app.allow_signup,
        .google_client_id = cfg.app.google_client_id,
        .workspace_creation_disabled = cfg.app.workspace_creation_disabled,
        .daemon_server_url = cfg.app.daemon_server_url,
        .daemon_app_url = cfg.app.daemon_app_url,
        .posthog_key = cfg.app.posthog_key,
        .posthog_host = cfg.app.posthog_host,
        .analytics_environment = cfg.app.analytics_environment,
    });
}
