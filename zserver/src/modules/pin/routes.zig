//! Pin module — route registration.
//!
//! Matches the old `src/routes/pin.zig` shape exactly: same paths,
//! same workspace-member interceptor, same handler functions (now
//! living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/pins");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listPins);
    try api.post("", handler.createPin);
    try api.get("/", handler.listPins);
    try api.post("/", handler.createPin);
    try api.post("/reorder", handler.reorderPins);
    try api.delete("/:itemType/:itemId", handler.deletePin);
}
