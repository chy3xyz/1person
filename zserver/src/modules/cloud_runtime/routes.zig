//! Cloud runtime module — route registration.
//!
//! Mirrors the Go server's `/api/cloud-runtime/nodes` endpoint set
//! (start / stop / reboot / exec / status). Gated by
//! `RequireWorkspaceMember` like the rest of the workspace-scoped
//! routes.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/cloud-runtime");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("/nodes", handler.listCloudNodes);
    try api.post("/nodes", handler.createCloudNode);
    try api.post("/nodes/:id/start", handler.startCloudNode);
    try api.post("/nodes/:id/stop", handler.stopCloudNode);
    try api.post("/nodes/:id/reboot", handler.rebootCloudNode);
    try api.post("/nodes/:id/exec", handler.execOnCloudNode);
    try api.get("/nodes/:id/status", handler.getCloudNodeStatus);
}
