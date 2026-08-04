//! Agent module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/agents");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listAgents);
    try api.post("", handler.createAgent);
    try api.get("/", handler.listAgents);
    try api.post("/", handler.createAgent);

    try api.get("/:id", handler.getAgent);
    try api.patch("/:id", handler.updateAgent);
    try api.delete("/:id", handler.archiveAgent);
    try api.post("/:id/restore", handler.restoreAgent);
    try api.post("/:id/cancel-tasks", handler.cancelTasks);

    try api.get("/:id/env", handler.getEnv);
    try api.put("/:id/env", handler.setEnv);

    try api.get("/:id/tasks", handler.listTasks);

    try api.get("/:id/skills", handler.listAgentSkills);
    try api.put("/:id/skills", handler.setAgentSkills);
    try api.post("/:id/skills", handler.addAgentSkills);
}
