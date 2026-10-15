//! Attachment module — route registration.
//!
//! Mirrors the old `src/routes/attachment.zig` shape exactly: same
//! paths, same workspace-member interceptor on the metadata
//! endpoints, the `serveUploads` top-level route on `/uploads/:id`,
//! and the auth-only `/api/upload-file` + `/api/attachments/:id/download`
//! endpoints (no workspace middleware in the Go backend; kept as
//! parity here).

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    // Auth-only endpoints (no workspace middleware in Go; keep parity here).
    try app.post("/api/upload-file", handler.uploadFile);
    try app.get("/api/attachments/:id/download", handler.downloadAttachment);
    // Markdown download links resolve their own workspace, so this one
    // deliberately sits outside the RequireWorkspaceMember group below — that
    // interceptor would reject a link opened from a different workspace, which
    // is exactly the case durable links have to survive. Authorization lives
    // in the handler: membership of the attachment's OWN workspace.
    try app.get("/api/attachments/:id/download-metadata", handler.getAttachmentForDownload);

    // Top-level upload serving endpoint. Registered at the app
    // level (not under the workspace-scoped group) because uploads
    // can also be served for files that were uploaded before the
    // workspace context was established.
    try app.get("/uploads/:id", handler.serveUploads);

    // Workspace-scoped attachment metadata endpoints.
    var api = zfinal.RouteGroup.init(app, "/api/attachments");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("/:id", handler.getAttachmentByID);
    try api.get("/:id/content", handler.getAttachmentContent);
    try api.delete("/:id", handler.deleteAttachment);
}
