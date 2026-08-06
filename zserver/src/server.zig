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

    // The single zfinal.ConnectionPool that backs every handler. Lives
    // in `deps.pool`; handlers borrow from it via `deps.acquire()`.
    // An empty db_url (e.g. `DATABASE_URL=""` from the e2e scripts)
    // means "run without a database" — do NOT fall back to libpq's
    // localhost default, which would silently target the wrong database
    // and make every table-backed query fail.
    if (cfg.db_url.len > 0) deps.initPool(allocator, cfg.db_url);
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

    log.info("server starting on port {}", .{cfg.port});
    try app.start();
}
