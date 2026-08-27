//! Content-matrix module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/content-matrix");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Platform CRUD
    try api.get("/platforms", handler.listPlatforms);
    try api.post("/platforms", handler.createPlatform);
    try api.get("/platforms/:id", handler.getPlatform);
    try api.put("/platforms/:id", handler.updatePlatform);
    try api.delete("/platforms/:id", handler.deletePlatform);

    // Distribution
    try api.post("/distribute", handler.distributeContent);

    // Results
    try api.get("/results", handler.listResults);
    try api.get("/results/:id", handler.getResult);
}
