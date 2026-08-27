//! Task module — route registration.
//!
//! Matches the old `src/routes/task.zig` shape exactly: same paths,
//! same workspace-member interceptor, same handler functions (now
//! living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/tasks");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("/:taskId/messages", handler.listTaskMessagesByUser);
    try api.post("/:taskId/cancel", handler.cancelTaskByUser);
}
