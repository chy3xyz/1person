//! Issue module — thin HTTP delegates.
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

pub fn listIssues(ctx: *zfinal.Context) !void {
    try service.listIssues(ctx);
}

pub fn getIssue(ctx: *zfinal.Context) !void {
    try service.getIssue(ctx);
}

pub fn createIssue(ctx: *zfinal.Context) !void {
    try service.createIssue(ctx);
}

pub fn updateIssue(ctx: *zfinal.Context) !void {
    try service.updateIssue(ctx);
}

pub fn deleteIssue(ctx: *zfinal.Context) !void {
    try service.deleteIssue(ctx);
}

pub fn attachLabel(ctx: *zfinal.Context) !void {
    try service.attachLabel(ctx);
}

pub fn detachLabel(ctx: *zfinal.Context) !void {
    try service.detachLabel(ctx);
}

pub fn listAttachments(ctx: *zfinal.Context) !void {
    try service.listAttachments(ctx);
}

pub fn searchIssues(ctx: *zfinal.Context) !void {
    try service.searchIssues(ctx);
}

pub fn batchUpdate(ctx: *zfinal.Context) !void {
    try service.batchUpdate(ctx);
}

pub fn batchDelete(ctx: *zfinal.Context) !void {
    try service.batchDelete(ctx);
}

pub fn quickCreate(ctx: *zfinal.Context) !void {
    try service.quickCreate(ctx);
}

pub fn rerun(ctx: *zfinal.Context) !void {
    try service.rerun(ctx);
}

pub fn childProgress(ctx: *zfinal.Context) !void {
    try service.childProgress(ctx);
}

pub fn groupedIssues(ctx: *zfinal.Context) !void {
    try service.groupedIssues(ctx);
}

pub fn listChildren(ctx: *zfinal.Context) !void {
    try service.listChildren(ctx);
}

pub fn listChildrenByParents(ctx: *zfinal.Context) !void {
    try service.listChildrenByParents(ctx);
}

pub fn listTimeline(ctx: *zfinal.Context) !void {
    try service.listTimeline(ctx);
}

pub fn listSubscribers(ctx: *zfinal.Context) !void {
    try service.listSubscribers(ctx);
}

pub fn addSubscriber(ctx: *zfinal.Context) !void {
    try service.addSubscriber(ctx);
}

pub fn removeSubscriber(ctx: *zfinal.Context) !void {
    try service.removeSubscriber(ctx);
}

pub fn listReactions(ctx: *zfinal.Context) !void {
    try service.listReactions(ctx);
}

pub fn addReaction(ctx: *zfinal.Context) !void {
    try service.addReaction(ctx);
}

pub fn removeReaction(ctx: *zfinal.Context) !void {
    try service.removeReaction(ctx);
}

pub fn getMetadata(ctx: *zfinal.Context) !void {
    try service.getMetadata(ctx);
}

pub fn setMetadata(ctx: *zfinal.Context) !void {
    try service.setMetadata(ctx);
}

pub fn squadEvaluated(ctx: *zfinal.Context) !void {
    try service.squadEvaluated(ctx);
}

pub fn previewCommentTriggers(ctx: *zfinal.Context) !void {
    try service.previewCommentTriggers(ctx);
}

pub fn activeTask(ctx: *zfinal.Context) !void {
    try service.activeTask(ctx);
}

pub fn taskRuns(ctx: *zfinal.Context) !void {
    try service.taskRuns(ctx);
}

pub fn issueUsage(ctx: *zfinal.Context) !void {
    try service.issueUsage(ctx);
}

pub fn pullRequests(ctx: *zfinal.Context) !void {
    try service.pullRequests(ctx);
}

pub fn setMetadataKey(ctx: *zfinal.Context) !void {
    try service.setMetadataKey(ctx);
}

pub fn deleteMetadataKey(ctx: *zfinal.Context) !void {
    try service.deleteMetadataKey(ctx);
}

pub fn subscribeIssue(ctx: *zfinal.Context) !void {
    try service.subscribeIssue(ctx);
}

pub fn unsubscribeIssue(ctx: *zfinal.Context) !void {
    try service.unsubscribeIssue(ctx);
}

pub fn removeReactionByEmoji(ctx: *zfinal.Context) !void {
    try service.removeReactionByEmoji(ctx);
}

pub fn listIssueLabels(ctx: *zfinal.Context) !void {
    try service.listIssueLabels(ctx);
}
