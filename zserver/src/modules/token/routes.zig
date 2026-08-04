//! Personal access token module — route registration.
//!
//! Matches the old `src/routes/token.zig` shape exactly: same paths,
//! same handler functions (now living in this module's `handler.zig`).
//! Unlike most modules, token routes are mounted at the app root (no
//! `RequireWorkspaceMember` interceptor — the caller authenticates via
//! the bearer token itself).

const std = @import("std");
const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    _ = std;
    try app.get("/api/tokens", handler.listTokens);
    try app.post("/api/tokens", handler.createToken);
    try app.post("/api/tokens/current/renew", handler.renewCurrentToken);
    try app.delete("/api/tokens/:id", handler.revokeToken);
}