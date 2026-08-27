//! Role module — route registration.
//!
//! Registers two route groups under `/api/roles`:
//!   - `/api/roles/defs` — RoleConfig CRUD
//!   - `/api/roles/members` — MemberRole assignment + tree queries

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    // ── RoleConfig (definitions) ──────────────────────────────────────
    var defs = zfinal.RouteGroup.init(app, "/api/roles/defs");
    defer defs.deinit();
    try defs.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Trailing-slash variants: zfinal's router does NOT normalize
    // `/api/roles/defs` vs `/api/roles/defs/`, so register both forms
    // (see workspace/routes.zig for the same pattern).
    try defs.get("", handler.listRoleConfigs);
    try defs.post("", handler.createRoleConfig);
    try defs.get("/", handler.listRoleConfigs);
    try defs.post("/", handler.createRoleConfig);

    try defs.get("/:id", handler.getRoleConfig);
    try defs.patch("/:id", handler.updateRoleConfig);
    try defs.delete("/:id", handler.deleteRoleConfig);

    // ── MemberRole (assignments) ──────────────────────────────────────
    var members = zfinal.RouteGroup.init(app, "/api/roles/members");
    defer members.deinit();
    try members.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try members.get("", handler.listMemberRoles);
    try members.post("", handler.assignRole);
    try members.get("/", handler.listMemberRoles);
    try members.post("/", handler.assignRole);

    try members.get("/:userId", handler.getMemberRole);
    try members.patch("/:userId", handler.updateMemberRole);
    try members.delete("/:userId", handler.deleteMemberRole);

    // ── Hierarchical queries ──────────────────────────────────────────
    try members.get("/:userId/downline", handler.getDownlineTree);
    try members.get("/:userId/upline", handler.getUplineChain);
}
