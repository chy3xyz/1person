//! Comment module — route registration.
//!
//! Mirrors the old `src/routes/comment.zig` shape exactly: two
//! route groups (`/api/issues/:id/comments` and `/api/comments`),
//! both gated by the `RequireWorkspaceMember` interceptor, with the
//! same handler functions (now living in this module's
//! `handler.zig`).

const std = @import("std");
const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    _ = std;
    var issue_api = zfinal.RouteGroup.init(app, "/api/issues");
    defer issue_api.deinit();
    try issue_api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try issue_api.get("/:id/comments", handler.listComments);
    try issue_api.post("/:id/comments", handler.createComment);
    // `POST /:id/comments/trigger-preview` is owned by the issue module
    // (issue/routes.zig) — that handler returns the `{agents: [...]}` shape
    // the frontend expects, whereas this module's is a `{triggers: []}` stub.
    // zfinal rejects duplicate method+pattern registrations at startup.

    var comment_api = zfinal.RouteGroup.init(app, "/api/comments");
    defer comment_api.deinit();
    try comment_api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try comment_api.get("/:commentId", handler.getComment);
    try comment_api.put("/:commentId", handler.updateComment);
    try comment_api.delete("/:commentId", handler.deleteComment);
    try comment_api.post("/:commentId/resolve", handler.resolveComment);
    try comment_api.delete("/:commentId/resolve", handler.unresolveComment);
    try comment_api.post("/:commentId/reactions", handler.addReaction);
    try comment_api.delete("/:commentId/reactions", handler.removeReaction);
}
