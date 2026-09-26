//! Daemon module — route registration.
//!
//! Mirrors the old `src/routes/daemon.zig` shape exactly: same paths
//! under `/api/daemon`, same handler functions (now living in this
//! module's `handler.zig`). The `/api/daemon` group is gated by the
//! dedicated `DaemonAuth` interceptor (see
//! `src/middleware/daemon_auth.zig`) which accepts `1d_` daemon
//! tokens in addition to the global `1p_` / `1t_` / `1c_`
//! prefixes. The global `AuthInterceptor` runs first and short-
//! circuits the daemon middleware via the `user_id` attribute.

const std = @import("std");
const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const daemon_mw = @import("../../middleware/daemon_auth.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    _ = std;
    var api = zfinal.RouteGroup.init(app, "/api/daemon");
    defer api.deinit();
    try api.addInterceptor(daemon_mw.DaemonAuthInterceptor);

    try api.post("/tokens", handler.mintDaemonToken);
    try api.post("/register", handler.daemonRegister);
    try api.post("/deregister", handler.daemonDeregister);
    try api.post("/heartbeat", handler.daemonHeartbeat);
    try api.get("/ws", handler.daemonWebSocket);
    try api.get("/workspaces/:workspaceId/repos", handler.getDaemonWorkspaceRepos);

    try api.post("/runtimes/:runtimeId/tasks/claim", handler.claimTaskByRuntime);
    try api.get("/runtimes/:runtimeId/tasks/pending", handler.listPendingTasksByRuntime);
    try api.post("/runtimes/:runtimeId/update/:updateId/result", handler.reportUpdateResult);
    try api.post("/runtimes/:runtimeId/models/:requestId/result", handler.reportModelListResult);
    try api.post("/runtimes/:runtimeId/local-skills/:requestId/result", handler.reportLocalSkillListResult);
    try api.post("/runtimes/:runtimeId/local-skills/import/:requestId/result", handler.reportLocalSkillImportResult);

    try api.get("/tasks/:taskId/status", handler.getTaskStatus);
    try api.post("/tasks/:taskId/start", handler.startTask);
    try api.post("/tasks/:taskId/wait-local-directory", handler.markTaskWaitingLocalDirectory);
    try api.post("/tasks/:taskId/progress", handler.reportTaskProgress);
    try api.post("/tasks/:taskId/complete", handler.completeTask);
    try api.post("/tasks/:taskId/fail", handler.failTask);
    try api.post("/tasks/:taskId/usage", handler.reportTaskUsage);
    try api.post("/tasks/:taskId/messages", handler.reportTaskMessages);
    try api.get("/tasks/:taskId/messages", handler.listTaskMessages);

    try api.get("/issues/:issueId/gc-check", handler.getIssueGCCheck);
    try api.get("/chat-sessions/:sessionId/gc-check", handler.getChatSessionGCCheck);
    try api.get("/autopilot-runs/:runId/gc-check", handler.getAutopilotRunGCCheck);
    try api.get("/tasks/:taskId/gc-check", handler.getTaskGCCheck);

    try api.post("/runtimes/:runtimeId/recover-orphans", handler.recoverOrphanedTasks);
    try api.post("/tasks/:taskId/session", handler.pinTaskSession);
}
