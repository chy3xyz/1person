//! Skill module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/skills");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listSkills);
    try api.post("", handler.createSkill);
    try api.get("/", handler.listSkills);
    try api.post("/", handler.createSkill);
    try api.get("/search", handler.searchSkills);
    try api.post("/import", handler.importSkill);

    try api.get("/:id", handler.getSkill);
    try api.patch("/:id", handler.updateSkill);
    try api.delete("/:id", handler.deleteSkill);

    try api.get("/:id/files", handler.listSkillFiles);
    try api.put("/:id/files", handler.upsertSkillFile);
    try api.delete("/:id/files/:path", handler.deleteSkillFile);
}
