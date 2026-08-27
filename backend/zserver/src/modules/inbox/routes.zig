//! Inbox module — route registration.
//!
//! Mirrors the old `src/routes/inbox.zig` shape exactly: same paths
//! under `/api/inbox` and `/api/inbox/admin`, same workspace-member
//! interceptor on the member surface, same admin-only
//! `RequireServiceOrWorkspaceRole("admin")` interceptor on the
//! `/admin` sub-tree, same handler functions (now living in this
//! module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/inbox");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listInbox);
    try api.get("/", handler.listInbox);
    try api.get("/since", handler.listInboxSince);
    try api.get("/unread-count", handler.countUnreadInbox);
    try api.post("/mark-all-read", handler.markAllInboxRead);
    try api.post("/archive-all", handler.archiveAllInbox);
    try api.post("/archive-all-read", handler.archiveAllReadInbox);
    try api.post("/archive-completed", handler.archiveCompletedInbox);
    try api.post("/:id/read", handler.markInboxRead);
    try api.post("/:id/archive", handler.archiveInboxItem);

    // Admin-only sub-tree. The `RequireServiceOrWorkspaceRole("admin")`
    // interceptor is stricter than the group's `member` interceptor so
    // workspace owners / admins can purge another user's replay log
    // without having to relax the rest of the inbox surface, and a
    // service caller (when `MULTICA_SERVICE_TOKEN` is configured) can
    // drive the same path without a workspace context.
    var admin_api = zfinal.RouteGroup.init(app, "/api/inbox/admin");
    defer admin_api.deinit();
    try admin_api.addInterceptor(workspace_mw.RequireServiceOrWorkspaceRole("admin"));
    try admin_api.post("/purge", handler.purgeInboxPair);
    try admin_api.get("/export", handler.exportInboxEvents);
}
