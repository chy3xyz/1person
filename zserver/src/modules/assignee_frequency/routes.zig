//! Assignee frequency module — route registration.
//!
//! Matches the old `src/routes/assignee_frequency.zig` shape exactly:
//! same paths, same workspace-member interceptor, same handler
//! functions (now living in this module's `handler.zig`).

const std = @import("std");
const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    _ = std;
    var api = zfinal.RouteGroup.init(app, "/api/assignee-frequency");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.getAssigneeFrequency);
    try api.get("/", handler.getAssigneeFrequency);
}