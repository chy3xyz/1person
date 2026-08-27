//! Dashboard module — route registration.
//!
//! Mirrors the old `src/routes/dashboard.zig` shape exactly: same
//! `/api/dashboard` prefix, same `RequireWorkspaceMember` interceptor,
//! same handler functions (now living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/dashboard");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("/usage/daily", handler.getDashboardUsageDaily);
    try api.get("/usage/by-agent", handler.getDashboardUsageByAgent);
    try api.get("/agent-runtime", handler.getDashboardAgentRunTime);
    try api.get("/runtime/daily", handler.getDashboardRunTimeDaily);

    // V2: configurable analytics dashboard
    try api.get("/config", handler.getDashboardConfig);
    try api.get("/widget/:name", handler.getDashboardData);
}
