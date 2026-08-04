//! Workspace module — route registration.
//!
//! Mirrors the old `src/routes/workspace.zig` shape exactly: same
//! paths under `/api/workspaces`, same auth interceptor
//! (`RequireWorkspaceMember` from the `middleware/workspace.zig`
//! module) applied to the per-workspace group, same handler
//! functions (now living in this module's `handler.zig`).

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    // Support both /api/workspaces and /api/workspaces/ for broader client compatibility.
    try app.get("/api/workspaces", handler.listWorkspaces);
    try app.post("/api/workspaces", handler.createWorkspace);

    var api = zfinal.RouteGroup.init(app, "/api/workspaces");
    defer api.deinit();
    try api.get("/", handler.listWorkspaces);
    try api.post("/", handler.createWorkspace);

    // Multi-tenancy V2: tree / children at the top level (before :id group
    // so literal segments are not captured as :id).
    try app.get("/api/workspaces/tree", handler.getWorkspaceTree);
    try app.post("/api/workspaces/children", handler.createChildWorkspace);

    var specific = zfinal.RouteGroup.init(app, "/api/workspaces/:id");
    defer specific.deinit();
    try specific.addInterceptor(workspace_mw.RequireWorkspaceMember);
    try specific.get("", handler.getWorkspace);
    try specific.put("", handler.updateWorkspace);
    try specific.patch("", handler.updateWorkspace);
    try specific.delete("", handler.deleteWorkspace);
    try specific.get("/members", handler.listMembers);
    try specific.post("/members", handler.addMember);
    try specific.patch("/members/:memberId", handler.updateMemberRole);
    try specific.delete("/members/:memberId", handler.removeMember);
    try specific.post("/leave", handler.leaveWorkspace);
    try specific.get("/invitations", handler.listInvitations);
    try specific.post("/invitations", handler.createInvitation);
    try specific.delete("/invitations/:invitationId", handler.deleteInvitation);

    // Multi-tenancy V2: per-workspace children / limits.
    try specific.get("/children", handler.getChildren);
    try specific.get("/limits", handler.getLimit);
    try specific.put("/limits", handler.setLimit);

    // GitHub integration.
    try specific.get("/github/installations", handler.listGithubInstallations);
    try specific.get("/github/connect", handler.connectGithub);
    try specific.post("/github/connect", handler.connectGithubInstallation);
    try specific.delete("/github/installations/:installationId", handler.deleteGithubInstallation);

    // Lark integration.
    try specific.get("/lark/installations", handler.listLarkInstallations);
    try specific.post("/lark/connect", handler.connectLark);
    try specific.delete("/lark/installations/:installationId", handler.deleteLarkInstallation);
    try specific.post("/lark/install/begin", handler.beginLarkInstall);
    try specific.get("/lark/install/:sessionId/status", handler.getLarkInstallStatus);
}
