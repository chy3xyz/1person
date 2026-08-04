//! Autopilot module — route registration.
//!
//! Mirrors the old `src/routes/autopilot.zig` shape exactly: same
//! paths under `/api/autopilots`, same workspace-member interceptor,
//! same handler functions (now living in this module's
//! `handler.zig`).

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/autopilots");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listAutopilots);
    try api.post("", handler.createAutopilot);
    try api.get("/", handler.listAutopilots);
    try api.post("/", handler.createAutopilot);

    try api.get("/:id", handler.getAutopilot);
    try api.patch("/:id", handler.updateAutopilot);
    try api.delete("/:id", handler.deleteAutopilot);

    try api.post("/:id/trigger", handler.triggerAutopilot);

    try api.get("/:id/triggers", handler.listTriggers);
    try api.post("/:id/triggers", handler.createTrigger);
    try api.patch("/:id/triggers/:triggerId", handler.updateTrigger);
    try api.delete("/:id/triggers/:triggerId", handler.deleteTrigger);
    try api.put("/:id/triggers/:triggerId/signing-secret", handler.setSigningSecret);

    try api.get("/:id/runs", handler.listRuns);
    try api.get("/:id/runs/:runId", handler.getRun);

    try api.get("/:id/deliveries", handler.listDeliveries);
    try api.get("/:id/deliveries/:deliveryId", handler.getDelivery);
    try api.post("/:id/deliveries/:deliveryId/replay", handler.replayDelivery);
    try api.post("/:id/triggers/:triggerId/rotate-webhook-token", handler.rotateWebhookToken);
}
