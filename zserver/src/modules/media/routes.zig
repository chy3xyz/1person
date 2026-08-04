//! Media module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/media");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.list);
    try api.post("", handler.upload);
    try api.get("/", handler.list);
    try api.post("/", handler.upload);
    try api.get("/:id", handler.get);
    try api.delete("/:id", handler.deleteAsset);
}
