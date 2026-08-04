//! Agent template module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/agent-templates");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listTemplates);
    try api.post("", handler.createTemplate);
    try api.get("/", handler.listTemplates);
    try api.post("/", handler.createTemplate);
    try api.get("/:slug", handler.getTemplate);
    try api.patch("/:slug", handler.updateTemplate);
    try api.delete("/:slug", handler.deleteTemplate);
}
