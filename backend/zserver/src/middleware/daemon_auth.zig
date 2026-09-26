//! Daemon auth interceptor.
//!
//! Mirrors the Go server's DaemonAuth middleware. Accepts four
//! token formats in priority order:
//!
//! 1. `1d_` — daemon token. When a DB pool exists, the full token
//!    is verified against the `daemon_token` table (SHA-256 hash,
//!    not expired, daemon_id matches) — the same contract as the Go
//!    server's `GetDaemonTokenByHash`. In no-DB mode (dev/test
//!    only; production refuses to boot without a database) the prefix
//!    is accepted without lookup so smoke/e2e keep working.
//! 2. `1p_` / `1t_` / `1c_` — personal / task / cloud-node
//!    tokens. These are rejected here (401 `daemon_token_required`)
//!    unless the global `AuthInterceptor` already validated the
//!    request and set `user_id` on the context.
//!
//! If the global interceptor already ran (it always does, since it
//! is registered at the server level), this middleware short-
//! circuits to avoid duplicate work.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../deps.zig");
const auth_lib = @import("../auth.zig");

const log = std.log.scoped(.daemon_auth);

const MDT_PREFIX = "1d_";
const MUL_PREFIX = "1p_";
const MAT_PREFIX = "1t_";
const MCN_PREFIX = "1c_";

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
        // DB-backed verification (mirrors Go GetDaemonTokenByHash):
        // the token must exist in `daemon_token`, be unexpired, and its
        // stored daemon_id must match the id embedded in the token.
        // Skipped in no-DB mode only — production never reaches here
        // without a database (server.zig refuses to boot).
        if (deps.hasPool()) {
            if (!try verifyDaemonToken(ctx, token, daemon_id)) return false;
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

/// Verify a `1d_` token against the `daemon_token` table. The
/// full token (prefix included) is SHA-256 hashed, matching how the
/// pairing flow stores tokens via `CreateDaemonToken`. Fails closed
/// (503) when the pool is present but a connection cannot be acquired.
fn verifyDaemonToken(ctx: *zfinal.Context, token: []const u8, daemon_id: []const u8) !bool {
    const hash = try auth_lib.hashToken(ctx.allocator, token);
    defer ctx.allocator.free(hash);

    const db = deps.acquire() catch {
        log.err("DB acquire failed during daemon-token verification — rejecting request", .{});
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "database_unavailable" });
        return false;
    };
    defer deps.releaseBack(db);

    var rs = db.queryParams(
        "SELECT daemon_id FROM daemon_token WHERE token_hash = $1 AND expires_at > now()",
        &[_]zfinal.SqlParam{.{ .text = hash }},
    ) catch {
        log.err("daemon-token verification query failed", .{});
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "database_error" });
        return false;
    };
    defer rs.deinit();

    if (rs.rows.items.len == 0) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    }
    const stored_daemon_id = rs.rows.items[0].getText(0) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    };
    if (!std.mem.eql(u8, stored_daemon_id, daemon_id)) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return false;
    }
    return true;
}

pub const DaemonAuthInterceptor = zfinal.Interceptor{
    .name = "daemon_auth",
    .before = struct {
        fn before(ctx: *zfinal.Context) !bool {
            return try daemonAuthBefore(ctx);
        }
    }.before,
};

/// Public helper: extract `daemon_id` from a `1d_<id>` token. Used
/// by `daemon/service.zig::daemonRegister` to attribute the
/// registration to a specific daemon.
pub fn daemonIdFromToken(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, MDT_PREFIX)) return null;
    const id = token[MDT_PREFIX.len..];
    if (id.len == 0) return null;
    return id;
}
