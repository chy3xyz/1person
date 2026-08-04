//! Issue module — route registration.
//!
//! Mirrors the old `src/routes/issue.zig` shape exactly: same paths
//! under `/api/issues`, same workspace-member interceptor
//! (`RequireWorkspaceMember` from `middleware/workspace.zig`) applied
//! to the per-workspace group, same handler functions (now living
//! in this module's `handler.zig`).

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/issues");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Trailing-slash variants: zfinal's router does NOT normalize
    // `/api/issues` vs `/api/issues/`, so register both forms for the
    // root collection routes. `api.get("")` builds `/api/issues`
    // (no slash) inside the group, keeping the interceptor applied.
    try api.get("", handler.listIssues);
    try api.post("", handler.createIssue);

    try api.get("/", handler.listIssues);
    try api.get("/search", handler.searchIssues);
    try api.post("/", handler.createIssue);
    try api.post("/batch-update", handler.batchUpdate);
    try api.post("/batch-delete", handler.batchDelete);
    // Workspace-wide child progress (no :id — mirrors Go's route).
    try api.get("/child-progress", handler.childProgress);
    try api.get("/grouped", handler.groupedIssues);
    try api.get("/children", handler.listChildrenByParents);

    try api.get("/:id", handler.getIssue);
    try api.patch("/:id", handler.updateIssue);
    try api.delete("/:id", handler.deleteIssue);

    try api.post("/:id/quick-create", handler.quickCreate);
    try api.post("/:id/rerun", handler.rerun);

    // Go-alignment: comment trigger preview
    try api.post("/:id/comments/trigger-preview", handler.previewCommentTriggers);
    // Go-alignment: per-issue task views
    try api.get("/:id/active-task", handler.activeTask);
    try api.get("/:id/task-runs", handler.taskRuns);
    try api.get("/:id/usage", handler.issueUsage);
    // Go-alignment: linked pull requests
    try api.get("/:id/pull-requests", handler.pullRequests);
    // Go-alignment: subscribe/unsubscribe
    try api.post("/:id/subscribe", handler.subscribeIssue);
    try api.post("/:id/unsubscribe", handler.unsubscribeIssue);
    // Go-alignment: reaction removal by (emoji, actor) tuple
    try api.delete("/:id/reactions", handler.removeReactionByEmoji);

    try api.post("/:id/labels", handler.attachLabel);
    try api.delete("/:id/labels/:labelId", handler.detachLabel);
    try api.get("/:id/labels", handler.listIssueLabels);
    try api.get("/:id/attachments", handler.listAttachments);

    try api.get("/:id/children", handler.listChildren);
    try api.get("/:id/timeline", handler.listTimeline);
    try api.get("/:id/subscribers", handler.listSubscribers);
    try api.post("/:id/subscribers", handler.addSubscriber);
    // `removeSubscriber` takes a `:userId` path segment instead of
    // a JSON body because zfinal's `parseJsonBody` doesn't
    // preserve the request body for DELETE, and the
    // body-then-queryParam fallback triggered a use-after-free in
    // zfinal's `ensureQueryParams`. The legacy Go contract accepts
    // either; this path uses the more reliable one.
    try api.delete("/:id/subscribers/:userId", handler.removeSubscriber);
    // Squad-evaluated marker — same `/:id` shape as the other
    // per-issue routes, gated by `RequireWorkspaceMember` like them.
    try api.post("/:id/squad-evaluated", handler.squadEvaluated);
    try api.get("/:id/reactions", handler.listReactions);
    try api.post("/:id/reactions", handler.addReaction);
    try api.delete("/:id/reactions/:reactionId", handler.removeReaction);
    // Metadata: list (GET), set (PATCH), per-key (PUT/DELETE).
    try api.get("/:id/metadata", handler.getMetadata);
    try api.patch("/:id/metadata", handler.setMetadata);
    try api.put("/:id/metadata/:key", handler.setMetadataKey);
    try api.delete("/:id/metadata/:key", handler.deleteMetadataKey);
}
