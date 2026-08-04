//! Chat module — route registration.
//!
//! Mirrors the old `src/routes/chat.zig` shape exactly: same paths
//! under `/api/chat/sessions` and `/api/chat/pending-tasks`, same
//! workspace-member interceptor, same handler functions (now living
//! in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/chat/sessions");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listChatSessions);
    try api.post("", handler.createChatSession);
    try api.get("/", handler.listChatSessions);
    try api.post("/", handler.createChatSession);

    try api.get("/:sessionId", handler.getChatSession);
    try api.patch("/:sessionId", handler.updateChatSession);
    try api.delete("/:sessionId", handler.deleteChatSession);

    try api.post("/:sessionId/messages", handler.sendChatMessage);
    try api.get("/:sessionId/messages", handler.listChatMessages);
    try api.get("/:sessionId/messages/page", handler.listChatMessagesPage);

    try api.get("/:sessionId/pending-task", handler.getPendingChatTask);
    try api.post("/:sessionId/read", handler.markChatSessionRead);

    try app.get("/api/chat/pending-tasks", handler.listPendingChatTasks);
}
