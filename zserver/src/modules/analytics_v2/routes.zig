//! Analytics V2 module — route registration.
//!
//! Mirrors the dashboard module shape: `/api/analytics` prefix,
//! `RequireWorkspaceMember` interceptor, handler functions from
//! this module's `handler.zig`.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/analytics");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.post("/track", handler.trackMetric);
    try api.get("/query", handler.queryMetrics);
    try api.post("/reports", handler.generateReport);
    try api.get("/reports", handler.listReports);
    try api.get("/reports/:id", handler.getReport);
}
