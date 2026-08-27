//! Project module — route registration.
//!
//! Matches the old `src/routes/project.zig` shape exactly: same paths,
//! same workspace-member interceptor, same handler functions (now
//! living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/projects");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listProjects);
    try api.post("", handler.createProject);
    try api.get("/", handler.listProjects);
    try api.post("/", handler.createProject);

    try api.get("/:id", handler.getProject);
    // Frontend/Go contract uses PUT for updates; keep PATCH for back-compat.
    try api.put("/:id", handler.updateProject);
    try api.patch("/:id", handler.updateProject);
    try api.delete("/:id", handler.deleteProject);

    try api.get("/:id/resources", handler.listResources);
    try api.post("/:id/resources", handler.createResource);
    try api.put("/:id/resources/:resourceId", handler.updateResource);
    try api.delete("/:id/resources/:resourceId", handler.deleteResource);
}
