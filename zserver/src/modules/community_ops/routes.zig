//! Community ops module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/community");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Group CRUD
    try api.get("/groups", handler.listGroups);
    try api.post("/groups", handler.createGroup);
    try api.get("/groups/:id", handler.getGroup);
    try api.delete("/groups/:id", handler.deleteGroup);

    // Membership
    try api.post("/groups/:id/add-member", handler.addMember);
    try api.post("/groups/:id/remove-member", handler.removeMember);

    // Announcements
    try api.post("/groups/:id/announcements", handler.createAnnouncement);
    try api.post("/announcements/:id/publish", handler.publishAnnouncement);

    // Daily digest
    try api.get("/groups/:id/digest", handler.getDailyDigest);
}
