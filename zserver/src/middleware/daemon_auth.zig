//! Daemon auth interceptor.
//!
//! Mirrors the Go server's `DaemonAuth` middleware. Accepts four
//! token formats in priority order:
//!
//! 1. `mdt_` — daemon token (the part after the prefix is treated
//!    as the `daemon_id`; existence is NOT verified here)
//! 2. `mul_` / `mat_` / `mcn_` — personal / task / cloud-node
//!    tokens. These are rejected here (401 `daemon_token_required`)
//!    unless the global `AuthInterceptor` already validated the
//!    request and set `user_id` on the context.
//!
//! NOTE: the global `AuthInterceptor` only checks token *format*
//! (prefix + length) for `mul_`/`mat_`/`mcn_` — it does not verify
//! the token against the `personal_access_token` table. Real PAT
//! validation is not yet wired into the global auth path.
//!
//! If the global interceptor already ran (it always does, since it
//! is registered at the server level), this middleware short-
//! circuits to avoid duplicate work.

const std = @import("std");
const zfinal = @import("zfinal");

const log = std.log.scoped(.daemon_auth);

const MDT_PREFIX = "mdt_";
const MUL_PREFIX = "mul_";
const MAT_PREFIX = "mat_";
const MCN_PREFIX = "mcn_";

fn extractBearerToken(ctx: *zfinal.Context) ?[]const u8 {
    const header = ctx.getHeader("Authorization") orelse return null;
    const prefix = "Bearer ";
    if (header.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(header[0..prefix.len], prefix)) return null;
    const token = std.mem.trim(u8, header[prefix.len..], &std.ascii.whitespace);
    if (token.len == 0) return null;
    return token;
}

fn daemonAuthBefore(ctx: *zfinal.Context) !bool {
    // Short-circuit when the global auth interceptor has already
    // populated the context (this happens on every request that
    // passes the global gate).
    if (ctx.attributes.get("user_id") != null) return true;

    const token = extractBearerToken(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "missing_token" });
        return false;
    };

    if (std.mem.startsWith(u8, token, MDT_PREFIX)) {
        const daemon_id = token[MDT_PREFIX.len..];
        if (daemon_id.len == 0) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "daemon_token_invalid" });
            return false;
        }
        try ctx.setAttr("daemon_id", daemon_id);
        return true;
    }

    if (std.mem.startsWith(u8, token, MUL_PREFIX) or
        std.mem.startsWith(u8, token, MAT_PREFIX) or
        std.mem.startsWith(u8, token, MCN_PREFIX))
    {
        // Fallback: the global interceptor would have already
        // rejected this token. Surface a friendly error.
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
        return false;
    }

    ctx.res_status = .unauthorized;
    try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
    return false;
}

pub const DaemonAuthInterceptor = zfinal.Interceptor{
    .name = "daemon_auth",
    .before = struct {
        fn before(ctx: *zfinal.Context) !bool {
            return try daemonAuthBefore(ctx);
        }
    }.before,
};

/// Public helper: extract `daemon_id` from a `mdt_<id>` token. Used
/// by `daemon/service.zig::daemonRegister` to attribute the
/// registration to a specific daemon.
pub fn daemonIdFromToken(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, MDT_PREFIX)) return null;
    const id = token[MDT_PREFIX.len..];
    if (id.len == 0) return null;
    return id;
}
