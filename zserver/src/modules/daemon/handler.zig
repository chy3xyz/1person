//! Daemon module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn init(cfg: *const Config) void {
    service.init(cfg);
}

pub fn mintDaemonToken(ctx: *zfinal.Context) !void {
    try service.mintDaemonToken(ctx);
}

pub fn daemonRegister(ctx: *zfinal.Context) !void {
    try service.daemonRegister(ctx);
}

pub fn daemonDeregister(ctx: *zfinal.Context) !void {
    try service.daemonDeregister(ctx);
}

pub fn daemonHeartbeat(ctx: *zfinal.Context) !void {
    try service.daemonHeartbeat(ctx);
}

pub fn daemonWebSocket(ctx: *zfinal.Context) !void {
    try service.daemonWebSocket(ctx);
}

pub fn getDaemonWorkspaceRepos(ctx: *zfinal.Context) !void {
    try service.getDaemonWorkspaceRepos(ctx);
}

pub fn reportUpdateResult(ctx: *zfinal.Context) !void {
    try service.reportUpdateResult(ctx);
}

pub fn reportModelListResult(ctx: *zfinal.Context) !void {
    try service.reportModelListResult(ctx);
}

pub fn reportLocalSkillListResult(ctx: *zfinal.Context) !void {
    try service.reportLocalSkillListResult(ctx);
}

pub fn reportLocalSkillImportResult(ctx: *zfinal.Context) !void {
    try service.reportLocalSkillImportResult(ctx);
}

pub fn getTaskStatus(ctx: *zfinal.Context) !void {
    try service.getTaskStatus(ctx);
}

pub fn claimTaskByRuntime(ctx: *zfinal.Context) !void {
    try service.claimTaskByRuntime(ctx);
}

pub fn listPendingTasksByRuntime(ctx: *zfinal.Context) !void {
    try service.listPendingTasksByRuntime(ctx);
}

pub fn startTask(ctx: *zfinal.Context) !void {
    try service.startTask(ctx);
}

pub fn markTaskWaitingLocalDirectory(ctx: *zfinal.Context) !void {
    try service.markTaskWaitingLocalDirectory(ctx);
}

pub fn reportTaskProgress(ctx: *zfinal.Context) !void {
    try service.reportTaskProgress(ctx);
}

pub fn completeTask(ctx: *zfinal.Context) !void {
    try service.completeTask(ctx);
}

pub fn failTask(ctx: *zfinal.Context) !void {
    try service.failTask(ctx);
}

pub fn reportTaskUsage(ctx: *zfinal.Context) !void {
    try service.reportTaskUsage(ctx);
}

pub fn reportTaskMessages(ctx: *zfinal.Context) !void {
    try service.reportTaskMessages(ctx);
}

pub fn listTaskMessages(ctx: *zfinal.Context) !void {
    try service.listTaskMessages(ctx);
}

pub fn getIssueGCCheck(ctx: *zfinal.Context) !void {
    try service.getIssueGCCheck(ctx);
}

pub fn getChatSessionGCCheck(ctx: *zfinal.Context) !void {
    try service.getChatSessionGCCheck(ctx);
}

pub fn getAutopilotRunGCCheck(ctx: *zfinal.Context) !void {
    try service.getAutopilotRunGCCheck(ctx);
}

pub fn getTaskGCCheck(ctx: *zfinal.Context) !void {
    try service.getTaskGCCheck(ctx);
}

pub fn recoverOrphanedTasks(ctx: *zfinal.Context) !void {
    try service.recoverOrphanedTasks(ctx);
}

pub fn pinTaskSession(ctx: *zfinal.Context) !void {
    try service.pinTaskSession(ctx);
}
