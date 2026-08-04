//! HTTP route registration.
//!
//! The new layout follows the zfinal `examples/ruoyi-gen/` convention:
//! every business domain lives under `src/modules/<name>/` with its
//! own `{handler, service, model, routes}.zig`. This file is the
//! thin top-level shell that iterates the module list and registers
//! the global interceptors + cross-cutting endpoints.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("config.zig").Config;
const deps = @import("deps.zig");
const health = @import("health.zig");

/// Per-domain module list. Each entry is `@import`'d at compile time
/// inside `registerAll` and its `routes::register` is invoked in
/// order. The order mirrors the original `src/router.zig` so
/// behaviour is unchanged; reordering is safe (zfinal's router
/// matches by pattern, not insertion order).
const modules = [_][]const u8{
    "config",            "auth",            "realtime",
    "attachment",        "user",            "workspace",
    "invitation",        "lark",            "token",
    "billing",           "assignee_frequency",
    "issue",             "task",            "label",
    "project",           "squad",           "autopilot",
    "pin",               "comment",         "agent",
    "agent_template",    "skill",           "analytics_v2",
    "dashboard",
    "runtime",           "chat",            "inbox",
    "notification_preference",              "daemon",
    "webhook",           "connector",       "contact",         "health_realtime",
    "cloud_runtime",     "pipeline",        "commission",
    "compliance",        "role",            "referral",
    "content_matrix",
    "wallet",            "token_economy",
    "training",          "community_ops",
    "i18n",              "notification",
    "scheduler",
    "media",
    "blockchain",       "task_queue_v2",
};

fn resolveModule(comptime name: []const u8) type {
    @setEvalBranchQuota(3000);
    if (std.mem.eql(u8, name, "config")) return @import("modules/config/routes.zig");
    if (std.mem.eql(u8, name, "auth")) return @import("modules/auth/routes.zig");
    if (std.mem.eql(u8, name, "realtime")) return @import("modules/realtime/routes.zig");
    if (std.mem.eql(u8, name, "attachment")) return @import("modules/attachment/routes.zig");
    if (std.mem.eql(u8, name, "user")) return @import("modules/user/routes.zig");
    if (std.mem.eql(u8, name, "workspace")) return @import("modules/workspace/routes.zig");
    if (std.mem.eql(u8, name, "invitation")) return @import("modules/invitation/routes.zig");
    if (std.mem.eql(u8, name, "lark")) return @import("modules/lark/routes.zig");
    if (std.mem.eql(u8, name, "token")) return @import("modules/token/routes.zig");
    if (std.mem.eql(u8, name, "billing")) return @import("modules/billing/routes.zig");
    if (std.mem.eql(u8, name, "assignee_frequency")) return @import("modules/assignee_frequency/routes.zig");
    if (std.mem.eql(u8, name, "issue")) return @import("modules/issue/routes.zig");
    if (std.mem.eql(u8, name, "task")) return @import("modules/task/routes.zig");
    if (std.mem.eql(u8, name, "label")) return @import("modules/label/routes.zig");
    if (std.mem.eql(u8, name, "project")) return @import("modules/project/routes.zig");
    if (std.mem.eql(u8, name, "squad")) return @import("modules/squad/routes.zig");
    if (std.mem.eql(u8, name, "autopilot")) return @import("modules/autopilot/routes.zig");
    if (std.mem.eql(u8, name, "pin")) return @import("modules/pin/routes.zig");
    if (std.mem.eql(u8, name, "comment")) return @import("modules/comment/routes.zig");
    if (std.mem.eql(u8, name, "agent")) return @import("modules/agent/routes.zig");
    if (std.mem.eql(u8, name, "agent_template")) return @import("modules/agent_template/routes.zig");
    if (std.mem.eql(u8, name, "skill")) return @import("modules/skill/routes.zig");
    if (std.mem.eql(u8, name, "analytics_v2")) return @import("modules/analytics_v2/routes.zig");
    if (std.mem.eql(u8, name, "dashboard")) return @import("modules/dashboard/routes.zig");
    if (std.mem.eql(u8, name, "runtime")) return @import("modules/runtime/routes.zig");
    if (std.mem.eql(u8, name, "chat")) return @import("modules/chat/routes.zig");
    if (std.mem.eql(u8, name, "inbox")) return @import("modules/inbox/routes.zig");
    if (std.mem.eql(u8, name, "notification_preference")) return @import("modules/notification_preference/routes.zig");
    if (std.mem.eql(u8, name, "daemon")) return @import("modules/daemon/routes.zig");
    if (std.mem.eql(u8, name, "webhook")) return @import("modules/webhook/routes.zig");
    if (std.mem.eql(u8, name, "connector")) return @import("modules/connector/routes.zig");
    if (std.mem.eql(u8, name, "contact")) return @import("modules/contact/routes.zig");
    if (std.mem.eql(u8, name, "health_realtime")) return @import("modules/health_realtime/routes.zig");
    if (std.mem.eql(u8, name, "cloud_runtime")) return @import("modules/cloud_runtime/routes.zig");
    if (std.mem.eql(u8, name, "pipeline")) return @import("modules/pipeline/routes.zig");
    if (std.mem.eql(u8, name, "commission")) return @import("modules/commission/routes.zig");
    if (std.mem.eql(u8, name, "compliance")) return @import("modules/compliance/routes.zig");
    if (std.mem.eql(u8, name, "role")) return @import("modules/role/routes.zig");
    if (std.mem.eql(u8, name, "referral")) return @import("modules/referral/routes.zig");
    if (std.mem.eql(u8, name, "content_matrix")) return @import("modules/content_matrix/routes.zig");
    if (std.mem.eql(u8, name, "wallet")) return @import("modules/wallet/routes.zig");
    if (std.mem.eql(u8, name, "token_economy")) return @import("modules/token_economy/routes.zig");
    if (std.mem.eql(u8, name, "training")) return @import("modules/training/routes.zig");
    if (std.mem.eql(u8, name, "community_ops")) return @import("modules/community_ops/routes.zig");
    if (std.mem.eql(u8, name, "i18n")) return @import("modules/i18n/routes.zig");
    if (std.mem.eql(u8, name, "notification")) return @import("modules/notification/routes.zig");
    if (std.mem.eql(u8, name, "scheduler")) return @import("modules/scheduler/routes.zig");
    if (std.mem.eql(u8, name, "media")) return @import("modules/media/routes.zig");
    if (std.mem.eql(u8, name, "blockchain")) return @import("modules/blockchain/routes.zig");
    if (std.mem.eql(u8, name, "task_queue_v2")) return @import("modules/task_queue_v2/routes.zig");
    @compileError("unknown module: " ++ name);
}

/// `redis_client` is kept in the signature for compatibility but is
/// currently unused here; the redis connection lives in the
/// `redis.zig` global.
pub fn registerAll(app: *zfinal.ZFinal, allocator: std.mem.Allocator, cfg: *const Config, redis_client: ?*zfinal.RedisClient) !void {
    _ = redis_client;
    _ = allocator;
    _ = deps;

    @import("modules/config/handler.zig").setConfig(cfg);
    @import("modules/auth/handler.zig").init(cfg);
    @import("modules/daemon/handler.zig").init(cfg);
    @import("modules/comment/handler.zig").init(cfg);
    @import("modules/user/handler.zig").init(cfg);
    @import("modules/workspace/handler.zig").init(cfg);
    @import("modules/blockchain/handler.zig").init(cfg);

    try app.get("/health", health.live);
    try app.get("/readyz", health.ready);
    try app.get("/healthz", health.ready);

    // The realtime module's only HTTP route is the `/ws` WebSocket
    // upgrade. It is registered inline here (rather than via the
    // module's `routes::register`) because the WS handler is a
    // single, special-cased endpoint that doesn't fit the per-module
    // group-shape used by every other route.
    try app.get("/ws", @import("modules/realtime/handler.zig").handleRealtime);

    @setEvalBranchQuota(3000);
    inline for (modules) |name| {
        const mod = resolveModule(name);
        try mod.register(app);
    }
}
