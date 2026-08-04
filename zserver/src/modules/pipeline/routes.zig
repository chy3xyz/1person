//! Pipeline module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/pipelines");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Pipeline config CRUD
    try api.get("", handler.listPipelineConfigs);
    try api.post("", handler.createPipelineConfig);
    try api.get("/", handler.listPipelineConfigs);
    try api.post("/", handler.createPipelineConfig);
    try api.get("/:id", handler.getPipelineConfig);
    try api.patch("/:id", handler.updatePipelineConfig);
    try api.delete("/:id", handler.deletePipelineConfig);

    // Pipeline run
    try api.post("/:id/start", handler.startPipeline);
    try api.get("/:id/runs", handler.listPipelineRuns);
    try api.get("/:id/runs/:runId", handler.getPipelineRun);
    try api.post("/:id/runs/:runId/phases/:phaseId/complete", handler.completePhase);
}
