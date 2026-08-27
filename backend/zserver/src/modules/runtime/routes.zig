//! Runtime module — route registration.
//!
//! Matches the old `src/routes/runtime.zig` shape exactly: same
//! paths, same workspace interceptor, same handler functions (now
//! living in this module's `handler.zig`). The legacy
//! `src/routes/cloud_runtime.zig` stub is gone — it was a no-op that
//! is intentionally not re-registered here.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/runtimes");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listAgentRuntimes);
    try api.get("/", handler.listAgentRuntimes);
    try api.patch("/:runtimeId", handler.updateAgentRuntime);

    try api.get("/:runtimeId/usage", handler.getRuntimeUsage);
    try api.get("/:runtimeId/usage/by-agent", handler.getRuntimeUsageByAgent);
    try api.get("/:runtimeId/usage/by-hour", handler.getRuntimeUsageByHour);
    try api.get("/:runtimeId/activity", handler.getRuntimeTaskActivity);

    try api.post("/:runtimeId/update", handler.initiateUpdate);
    try api.get("/:runtimeId/update/:updateId", handler.getUpdate);

    try api.post("/:runtimeId/models", handler.initiateListModels);
    try api.get("/:runtimeId/models/:requestId", handler.getModelListRequest);

    try api.post("/:runtimeId/local-skills", handler.initiateListLocalSkills);
    try api.get("/:runtimeId/local-skills/:requestId", handler.getLocalSkillListRequest);
    try api.post("/:runtimeId/local-skills/import", handler.initiateImportLocalSkill);
    try api.get("/:runtimeId/local-skills/import/:requestId", handler.getLocalSkillImportRequest);

    try api.delete("/:runtimeId", handler.deleteAgentRuntime);
    try api.post("/:runtimeId/archive-agents-and-delete", handler.archiveAgentsAndDeleteRuntime);
}
