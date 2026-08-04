//! Connector module — route registration.
//!
//! Registers all endpoints under `/api/connectors` with the
//! `RequireWorkspaceMember` interceptor.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/connectors");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listConfigs);
    try api.post("", handler.createConfig);
    try api.get("/", handler.listConfigs);
    try api.post("/", handler.createConfig);

    try api.get("/:id", handler.getConfig);
    try api.patch("/:id", handler.updateConfig);
    try api.delete("/:id", handler.deleteConfig);

    try api.post("/:id/call", handler.call);
    try api.get("/:id/logs", handler.listLogs);
}
