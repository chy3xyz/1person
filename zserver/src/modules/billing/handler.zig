//! Billing module — thin HTTP delegates.
//!
//! All real logic lives in `service.zig` and `model.zig`. This file
//! is a 1-line passthrough per route, matching the zfinal
//! `examples/ruoyi-gen/` convention.
//!
//! Note: this is a "dummy" partial migration — `routes.zig` still
//! shims to the legacy `src/routes/billing.zig` and
//! `src/routes/cloud_billing.zig` for this turn. Future turns can
//! replace the shim with a direct registration that uses these
//! delegates.

const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const service = @import("service.zig");

pub fn init(cfg: *const Config) void {
    service.init(cfg);
}

pub fn getCloudBillingBalance(ctx: *zfinal.Context) !void {
    try service.getCloudBillingBalance(ctx);
}

pub fn listCloudBillingTransactions(ctx: *zfinal.Context) !void {
    try service.listCloudBillingTransactions(ctx);
}

pub fn listCloudBillingBatches(ctx: *zfinal.Context) !void {
    try service.listCloudBillingBatches(ctx);
}

pub fn listCloudBillingTopups(ctx: *zfinal.Context) !void {
    try service.listCloudBillingTopups(ctx);
}

pub fn listCloudBillingPriceTiers(ctx: *zfinal.Context) !void {
    try service.listCloudBillingPriceTiers(ctx);
}

pub fn createCloudBillingCheckoutSession(ctx: *zfinal.Context) !void {
    try service.createCloudBillingCheckoutSession(ctx);
}

pub fn getCloudBillingCheckoutSession(ctx: *zfinal.Context) !void {
    try service.getCloudBillingCheckoutSession(ctx);
}

pub fn createCloudBillingPortalSession(ctx: *zfinal.Context) !void {
    try service.createCloudBillingPortalSession(ctx);
}

pub fn listInvoices(ctx: *zfinal.Context) !void {
    try service.listInvoices(ctx);
}

pub fn getInvoice(ctx: *zfinal.Context) !void {
    try service.getInvoice(ctx);
}

pub fn getSubscription(ctx: *zfinal.Context) !void {
    try service.getSubscription(ctx);
}

pub fn listUsage(ctx: *zfinal.Context) !void {
    try service.listUsage(ctx);
}

pub fn listPaymentMethods(ctx: *zfinal.Context) !void {
    try service.listPaymentMethods(ctx);
}

pub fn getBillingDetails(ctx: *zfinal.Context) !void {
    try service.getBillingDetails(ctx);
}

pub fn updateBillingDetails(ctx: *zfinal.Context) !void {
    try service.updateBillingDetails(ctx);
}
