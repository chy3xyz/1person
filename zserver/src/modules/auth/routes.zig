//! Auth module — route registration.
//!
//! Matches the old `src/routes/auth.zig` shape exactly: same paths,
//! same rate-limit interceptors, same handler functions (now living
//! in this module's `handler.zig`).

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const ratelimit = @import("../../middleware/ratelimit.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    try app.postWithInterceptors("/auth/send-code", handler.sendCode, &.{ratelimit.RateLimitAuthInterceptor});
    try app.postWithInterceptors("/auth/verify-code", handler.verifyCode, &.{ratelimit.RateLimitAuthVerifyInterceptor});
    try app.post("/auth/google", handler.googleAuth);
    try app.post("/auth/logout", handler.logout);
}
