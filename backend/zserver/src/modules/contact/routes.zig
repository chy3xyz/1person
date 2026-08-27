//! Contact module — route registration.
//!
//! Replaces the Turn-1 re-export shim. The old `src/router.zig`
//! registered `/api/contact-sales` inline (no `src/routes/contact.zig`
//! ever existed); the registration lives here now and is invoked by
//! the top-level `router.zig::registerAll` through the
//! `resolveModule` chain.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    try app.post("/api/contact-sales", handler.contactSales);
}
