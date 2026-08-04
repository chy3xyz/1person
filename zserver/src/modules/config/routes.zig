//! Config module — route registration.
//!
//! The legacy layout had no `src/routes/config.zig`; the endpoint was
//! registered inline from the top-level `src/router.zig`. This file
//! preserves the historical `GET /api/config` shape using the new
//! module's `handler.zig` delegate.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    try app.get("/api/config", handler.getConfig);
}
