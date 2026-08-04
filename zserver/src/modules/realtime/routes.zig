//! Realtime module — route registration.
//!
//! The realtime module has exactly one HTTP route — `/ws` (the
//! WebSocket upgrade) — and it is wired inline in
//! `src/router.zig::registerAll` so the WS upgrade doesn't have to
//! pass through the per-module `routes::register` chain. All other
//! realtime exports (`publishInbox`, `publishChatMessage`,
//! `roomCount`, …) are pure in-process helpers consumed by other
//! modules (`chat`, `inbox`, `health_realtime`) and the unit tests;
//! they do not need their own HTTP surface.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `register` is
//! still a valid `pub fn` so the top-level router can iterate this
//! module; it's a deliberate no-op so the WS endpoint stays special.

const zfinal = @import("zfinal");

pub fn register(_: *zfinal.ZFinal) !void {}
