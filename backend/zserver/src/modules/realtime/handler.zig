//! Realtime module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. The realtime
//! module exposes a single HTTP route — `handleRealtime` (the `/ws`
//! WebSocket upgrade) — which is wired inline in
//! `src/router.zig::registerAll` rather than via the module's
//! `routes.zig::register`. The other public functions
//! (`publishInbox`, `publishChatMessage`, `roomCount`, `clientCount`,
//! `metrics`, `replaySnapshot`, `replaySnapshotParsed`, `purgePair`,
//! `appendAudit`, `ringApproxBytes`, `latestSeq`, `replaySince`,
//! `replaySinceStream`, `clearRingForTest`, `readTailJsonl`,
//! `readTodayAuditLines`) are re-exported as thin passthroughs so
//! callers in other modules can import them from a single
//! `handler.zig` shim if they prefer the convention.

const zfinal = @import("zfinal");
const service = @import("service.zig");

// HTTP handler — wired in src/router.zig::registerAll.
pub fn handleRealtime(ctx: *zfinal.Context) !void {
    try service.handleRealtime(ctx);
}

// Re-exports for cross-module consumers that prefer the handler
// convention. `service.zig` remains the canonical home; the handler
// shim exists only for symmetry with the other migrated modules.
pub const publishInbox = service.publishInbox;
pub const publishChatMessage = service.publishChatMessage;
pub const roomCount = service.roomCount;
pub const clientCount = service.clientCount;
pub const metrics = service.metrics;
pub const replaySnapshot = service.replaySnapshot;
pub const replaySnapshotParsed = service.replaySnapshotParsed;
pub const purgePair = service.purgePair;
pub const appendAudit = service.appendAudit;
pub const ringApproxBytes = service.ringApproxBytes;
pub const latestSeq = service.latestSeq;
pub const replaySince = service.replaySince;
pub const replaySinceStream = service.replaySinceStream;
pub const clearRingForTest = service.clearRingForTest;
pub const readTailJsonl = service.readTailJsonl;
pub const readTodayAuditLines = service.readTodayAuditLines;
