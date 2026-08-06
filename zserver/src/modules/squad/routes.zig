//! Squad module — route registration.
//!
//! Matches the old `src/routes/squad.zig` shape exactly: same paths,
//! same workspace-member interceptor, same handler functions (now
//! living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/squads");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listSquads);
    try api.post("", handler.createSquad);
    try api.get("/", handler.listSquads);
    try api.post("/", handler.createSquad);

    try api.get("/:id", handler.getSquad);
    // Frontend/Go contract uses PUT for updates; keep PATCH for back-compat.
    try api.put("/:id", handler.updateSquad);
    try api.patch("/:id", handler.updateSquad);
    try api.delete("/:id", handler.deleteSquad);

    try api.get("/:id/members", handler.listMembers);
    try api.post("/:id/members", handler.addMember);
    try api.delete("/:id/members", handler.removeMember);
    try api.get("/:id/members/status", handler.memberStatus);
}