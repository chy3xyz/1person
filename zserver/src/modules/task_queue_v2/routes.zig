//! Task Queue V2 module — route registration.
//!
//! Exposes general-purpose task queue endpoints under `/api/task-queue`
//! with workspace-member protection.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/task-queue");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Claim the highest-priority pending task (register before "/" catch-all).
    try api.post("/claim", handler.claim);

    // Enqueue (create) a new task.
    try api.post("", handler.enqueue);
    try api.post("/", handler.enqueue);

    // Transition a task to running.
    try api.post("/:id/start", handler.start);

    // Mark a task as done.
    try api.post("/:id/complete", handler.complete);

    // Mark a task as failed.
    try api.post("/:id/fail", handler.fail);

    // Retry a failed task.
    try api.post("/:id/retry", handler.retry);

    // List tasks with optional filters.
    try api.get("", handler.list);
    try api.get("/", handler.list);

    // Get queue stats (pending/running/done/failed counts).
    try api.get("/stats", handler.queueStats);
}
