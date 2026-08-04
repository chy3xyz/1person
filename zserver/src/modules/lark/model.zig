//! Lark module — data layer.
//!
//! In-memory only: the no-DB fallback stores binding codes (issued
//! by the workspace install flow) in `service.mem_bindings` so
//! `redeemLarkBinding` can still resolve and mark them. The DB path
//! lives inline in `service.zig` against the `lark_binding` table.

/// A pending lark binding code, keyed by the code string itself.
/// Once redeemed, `redeemed` flips to `true` and the row is no
/// longer eligible for re-redemption.
pub const BindingEntry = struct {
    code: []const u8,
    workspace_id: []const u8,
    tenant_key: []const u8,
    tenant_name: []const u8,
    redeemed: bool,
    created_at: []const u8,
};
