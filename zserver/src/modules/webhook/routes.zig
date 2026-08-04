//! Webhook module — route registration.
//!
//! Replaces the Turn-1 re-export shim. The old `src/router.zig`
//! registered all four webhook endpoints inline (no
//! `src/routes/webhook.zig` ever existed); the registration lives
//! here now and is invoked by the top-level
//! `router.zig::registerAll` through the `resolveModule` chain.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    try app.post("/api/webhooks/autopilots/:token", handler.autopilotWebhook);
    try app.post("/api/webhooks/github", handler.githubWebhook);
    try app.get("/api/github/setup", handler.githubSetup);
    try app.post("/api/webhooks/stripe", handler.stripeWebhook);
}
