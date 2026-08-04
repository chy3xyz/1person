//! User module — route registration.
//!
//! Mirrors the old `src/routes/user.zig` shape exactly: same paths
//! under `/api/me`, same auth interceptor chain (applied globally
//! by the server), same handler functions (now living in this
//! module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    try app.get("/api/me", handler.getMe);
    try app.patch("/api/me", handler.updateMe);

    // Onboarding sub-routes.
    try app.patch("/api/me/onboarding", handler.patchOnboarding);
    try app.post("/api/me/onboarding/complete", handler.completeOnboarding);
    try app.post("/api/me/onboarding/cloud-waitlist", handler.cloudWaitlist);
    try app.post("/api/me/onboarding/runtime-bootstrap", handler.runtimeBootstrap);
    try app.post("/api/me/onboarding/no-runtime-bootstrap", handler.noRuntimeBootstrap);

    // CLI token and feedback.
    try app.post("/api/cli-token", handler.createCliToken);
    try app.post("/api/feedback", handler.submitFeedback);
}
