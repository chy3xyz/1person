//! Realtime health module — data layer.
//!
//! The legacy handler rendered an inline anonymous struct; promoting
//! it to a named type lets `service.zig` own the JSON shape and makes
//! it easier to extend with new fields later.

/// Shape of the JSON response returned by `GET /health/realtime`.
/// `status` is always the string literal `"ok"`. When no
/// `RoomManager` has been initialised yet (no-DB fallback, pre-WS
/// traffic) `rooms` and `clients` are 0 and the timing fields are
/// the zero value — the field set is stable so clients can rely on
/// its presence.
pub const RealtimeHealthSnapshot = struct {
    status: []const u8,
    rooms: usize,
    clients: usize,
    last_tick_at_ms: i64,
    pruned_clients_total: u64,
    pruned_rooms_total: u64,
    tick_count: u64,
};
