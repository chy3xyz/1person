//! Scheduler module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/scheduler");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // CRUD
    try api.post("", handler.scheduleTask);
    try api.get("", handler.listTasks);
    try api.post("/", handler.scheduleTask);
    try api.get("/", handler.listTasks);

    // Actions — use flat paths with query param to avoid :id/trailing routing issues
    try api.post("/execute", handler.executeNow);
    try api.post("/cancel", handler.cancelTask);
    try api.post("/retry", handler.retryTask);

    // Get by id — MUST be last to avoid matching before action routes
    try api.get("/:id", handler.getTask);
}
