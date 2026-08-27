//! Notification module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

/// Register the notification routes on both prefixes: the frontend
/// contract uses `/api/notification/*` (singular), while older zserver
/// callers / e2e use `/api/notifications` (plural). Both stay active.
fn registerOn(app: *zfinal.ZFinal, prefix: []const u8) !void {
    var api = zfinal.RouteGroup.init(app, prefix);
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Template CRUD
    try api.get("/templates", handler.listTemplates);
    try api.post("/templates", handler.createTemplate);
    try api.get("/templates/:id", handler.getTemplate);
    try api.put("/templates/:id", handler.updateTemplate);
    try api.delete("/templates/:id", handler.deleteTemplate);

    // Send
    try api.post("/send", handler.send);

    // Logs
    try api.get("/logs", handler.getLogs);

    // Channels
    try api.get("/channels", handler.listChannels);
}

pub fn register(app: *zfinal.ZFinal) !void {
    try registerOn(app, "/api/notifications");
    try registerOn(app, "/api/notification");
}
