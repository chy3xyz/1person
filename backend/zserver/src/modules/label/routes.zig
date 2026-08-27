//! Label module — route registration.
//!
//! Matches the old `src/routes/label.zig` shape exactly: same paths,
//! same workspace-member interceptor, same handler functions (now
//! living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/labels");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listLabels);
    try api.post("", handler.createLabel);
    try api.get("/", handler.listLabels);
    try api.post("/", handler.createLabel);

    try api.get("/:id", handler.getLabel);
    // Frontend/Go contract uses PUT for updates; keep PATCH for back-compat.
    try api.put("/:id", handler.updateLabel);
    try api.patch("/:id", handler.updateLabel);
    try api.delete("/:id", handler.deleteLabel);
}
