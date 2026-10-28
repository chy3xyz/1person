//! HTTP server lifecycle using ZFinal.

const std = @import("std");
const zfinal = @import("zfinal");
const config = @import("config.zig");
const deps = @import("deps.zig");
const router = @import("router.zig");
const middleware = @import("middleware.zig");
const auth = @import("auth.zig");
const ratelimit = @import("middleware/ratelimit.zig");
const workspace_mw = @import("middleware/workspace.zig");
const redis = @import("redis.zig");
const token_handler = @import("modules/token/handler.zig");
const issue_handler = @import("modules/issue/handler.zig");
const project_handler = @import("modules/project/handler.zig");
const label_handler = @import("modules/label/handler.zig");
const squad_handler = @import("modules/squad/handler.zig");
const agent_handler = @import("modules/agent/handler.zig");
const skill_handler = @import("modules/skill/handler.zig");
const autopilot_handler = @import("modules/autopilot/handler.zig");
const pin_handler = @import("modules/pin/handler.zig");
const task_handler = @import("modules/task/handler.zig");
const billing_handler = @import("modules/billing/handler.zig");
const webhook_handler = @import("modules/webhook/handler.zig");
const contact_handler = @import("modules/contact/handler.zig");
const daemon_handler = @import("modules/daemon/handler.zig");
const comment_handler = @import("modules/comment/handler.zig");


const log = std.log.scoped(.server);

pub const Options = config.Options;

pub fn run(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, opts: Options) !void {
    var cfg = try config.load(allocator, environ, opts, zfinal.io_instance.io);
    defer cfg.deinit();

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(cfg.port);

    // zfinal's write deadline is measured from the FIRST write of a
    // response, not per write. That is correct for an HTTP response
    // (which finishes in milliseconds) but wrong for a WebSocket, whose
    // "response" never ends: with the 30s default, every socket silently
    // loses the ability to receive server pushes 30 seconds after it
    // connects — the client keeps thinking it is connected while nothing
    // arrives. Both long-lived endpoints in this server (`/ws` and
    // `/api/daemon/ws`) are affected.
    //
    // Disabling the deadline restores the correct behaviour for a
    // bidirectional stream. The read timeout still bounds the connection
    // lifetime: a peer that stops sending is dropped after 30s, and the
    // keepalive ping keeps a live peer alive.
    app.config.write_timeout_ms = 0;

    // The single zfinal.ConnectionPool that backs every handler. Lives
    // in `deps.pool`; handlers borrow from it via `deps.acquire()`.
    // An empty db_url (e.g. `DATABASE_URL=""` from the e2e scripts)
    // means "run without a database" — do NOT fall back to libpq's
    // localhost default, which would silently target the wrong database
    // and make every table-backed query fail.
    //
    // Production policy: no-DB mode is a dev/test-only convenience. It is
    // also a fail-open auth bypass (format-only token checks, "owner" role
    // for everyone), so in production the server refuses to start when a
    // database is unavailable — silently degrading would authenticate
    // arbitrary `1p_`/`1d_` tokens and grant workspace ownership.
    const prod = config.isProduction(cfg.app_env);
    if (cfg.db_url.len > 0) {
        const pool_ready = deps.initPool(allocator, cfg.db_url);
        if (!pool_ready and prod) {
            log.err("DATABASE_URL configured but the connection pool failed to initialise — refusing to start in production (no-DB fallback is a security hole)", .{});
            return error.DatabaseRequired;
        }
    } else if (prod) {
        log.err("DATABASE_URL is required in production — refusing to start without a database (no-DB mode is dev/test only)", .{});
        return error.DatabaseRequired;
    } else {
        log.warn("running WITHOUT a database (no-DB mode) — auth degrades to format-only token checks and workspace roles are granted to everyone. Dev/test only.", .{});
    }
    defer deps.deinit(allocator);

    if (cfg.redis_url) |url| {
        redis.init(allocator, url) catch |err| {
            log.warn("redis init failed ({}), continuing without Redis", .{err});
        };
    }
    defer redis.deinit();

    middleware.setConfig(&cfg);
    auth.setConfig(&cfg);
    ratelimit.setConfig(&cfg);
    workspace_mw.setConfig(&cfg);
    token_handler.init(&cfg);
    issue_handler.init(&cfg);
    project_handler.init(&cfg);
    label_handler.init(&cfg);
    squad_handler.init(&cfg);
    agent_handler.init(&cfg);
    skill_handler.init(&cfg);
    @import("modules/runtime/handler.zig").init(&cfg);
    @import("modules/attachment/handler.zig").init(&cfg);
    autopilot_handler.init(&cfg);
    pin_handler.init(&cfg);
    task_handler.init(&cfg);
    billing_handler.init(&cfg);
    webhook_handler.init(&cfg);
    contact_handler.init(&cfg);
    daemon_handler.init(&cfg);
    comment_handler.init(&cfg);

    // Must run first: every later `getHeader` (ours and zfinal's) reads the
    // snapshot instead of the connection reader.
    try app.router.global_interceptors.add(middleware.HeaderSnapshotInterceptor);
    try app.router.global_interceptors.add(middleware.RequestIdInterceptor);
    try app.router.global_interceptors.add(middleware.LoggingInterceptor);
    try app.router.global_interceptors.add(middleware.CORSInterceptor);
    try app.router.global_interceptors.add(middleware.SecurityHeadersInterceptor);
    try app.router.global_interceptors.add(middleware.AuthInterceptor);
    try app.router.global_interceptors.add(middleware.RecoverInterceptor);

    try router.registerAll(&app, allocator, &cfg, redis.client());

    // Graceful shutdown: zfinal's accept loop watches the shutdown flag
    // (closing the listener, draining in-flight connections up to the
    // configured drain timeout, then letting app.start() return). Without
    // this, SIGTERM/SIGINT kill the process immediately and open
    // WebSockets are dropped mid-frame.
    zfinal.shutdown.registerHandlers();

    // ...but that drain is not bounded in practice. zfinal reads from
    // client sockets with a 30s timeout on a thread pool sized by CPU
    // count, so the drain takes roughly (open connections / threads) x
    // 30s: on a 2-core runner with a few dozen keep-alive connections
    // left over from a test run, the process was still alive six minutes
    // after SIGTERM. A server that cannot be stopped is a server that
    // gets SIGKILLed by whatever supervises it — and an E2E harness that
    // waits on it hangs forever.
    //
    // So bound it here: once a shutdown is requested, leave on our own
    // after the drain budget zfinal allows (plus a small margin).
    startShutdownWatchdog(cfg.shutdown_grace_ms);

    log.info("server starting on port {}", .{cfg.port});
    try app.start();
}

/// Leave the process on our own if the graceful path has not finished.
///
/// Deliberately not a graceful shutdown: it exists so a stuck connection
/// cannot keep the process alive forever. The exit code is 0 because the
/// process was asked to stop, not because it failed.
fn startShutdownWatchdog(grace_ms: u64) void {
    const thread = std.Thread.spawn(.{}, shutdownWatchdogThread, .{grace_ms}) catch |err| {
        log.warn("could not start the shutdown watchdog: {}", .{err});
        return;
    };
    thread.detach();
}

fn shutdownWatchdogThread(grace_ms: u64) void {
    while (!zfinal.shutdown.isShuttingDown()) {
        sleepMs(100);
    }
    sleepMs(grace_ms);
    if (zfinal.shutdown.isShuttingDown()) {
        log.warn("shutdown grace period elapsed; exiting", .{});
        std.process.exit(0);
    }
}

/// Sleep for the given number of milliseconds.
///
/// `std.Thread.sleep` is gone in Zig 0.17 and the Io-based sleep would tie
/// the watchdog to the Io instance that is shutting down, so use the libc
/// call directly — the binary already links libc.
fn sleepMs(ms: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}
