//! Realtime health module — business logic.
//!
//! Owns no state. Reads `realtime.metrics()`, `realtime.roomCount()`,
//! and `realtime.clientCount()` on every request and renders a
//! `model.RealtimeHealthSnapshot`. `handler.zig` is a thin delegate.

const zfinal = @import("zfinal");
const realtime = @import("../../modules/realtime/service.zig");
const model = @import("model.zig");

pub fn getRealtimeHealth(ctx: *zfinal.Context) !void {
    // When no RoomManager has been initialised yet (no-DB fallback,
    // pre-WS-traffic), `metrics()` returns an all-zero snapshot. The
    // response shape is identical regardless so clients can rely on the
    // fields being present.
    const m = realtime.metrics();
    const snapshot = model.RealtimeHealthSnapshot{
        .status = "ok",
        .rooms = realtime.roomCount(),
        .clients = realtime.clientCount(),
        .last_tick_at_ms = m.last_tick_at_ms,
        .pruned_clients_total = m.pruned_clients_total,
        .pruned_rooms_total = m.pruned_rooms_total,
        .tick_count = m.tick_count,
    };
    try ctx.renderJson(snapshot);
}
