//! Lark module — thin HTTP delegate.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.
//!
//! No `init(cfg)` is exposed: the legacy handler had a `g_cfg`
//! global but never read it, so the migration drops it.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn redeemLarkBinding(ctx: *zfinal.Context) !void {
    try service.redeemLarkBinding(ctx);
}
