//! Invitation module — route registration.
//!
//! Mirrors the old `src/routes/invitation.zig` shape exactly: same
//! paths under `/api/invitations`, same handler functions (now living
//! in this module's `handler.zig`). The endpoints are user-scoped and
//! rely on the global `AuthInterceptor` for authentication; workspace
//! membership is enforced downstream by the `acceptInvitation` flow
//! itself.

const std = @import("std");
const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    _ = std;
    var api = zfinal.RouteGroup.init(app, "/api/invitations");
    defer api.deinit();
    try api.get("", handler.listMyInvitations);
    try api.get("/", handler.listMyInvitations);
    try api.get("/:id", handler.getMyInvitation);
    try api.post("/:id/accept", handler.acceptInvitation);
    try api.post("/:id/decline", handler.declineInvitation);
}
