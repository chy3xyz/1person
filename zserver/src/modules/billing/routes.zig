//! Billing module — route registration (cloud-billing endpoints).
//!
//! The legacy `src/routes/billing.zig` registered these endpoints
//! with a custom `RequireHumanActor` interceptor that rejected
//! task-token actors. That interceptor is preserved here.

const std = @import("std");
const zfinal = @import("zfinal");
const handler = @import("handler.zig");

const RequireHumanActor = zfinal.Interceptor{
    .name = "require-human-actor",
    .before = struct {
        fn before(ctx: *zfinal.Context) !bool {
            const token_type = ctx.attributes.get("token_type") orelse "";
            if (std.mem.eql(u8, token_type, "task")) {
                ctx.res_status = .forbidden;
                try ctx.renderJson(.{ .@"error" = "task_token_forbidden" });
                return false;
            }
            return true;
        }
    }.before,
};

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/cloud-billing");
    defer api.deinit();
    try api.addInterceptor(RequireHumanActor);

    try api.get("/balance", handler.getCloudBillingBalance);
    try api.get("/transactions", handler.listCloudBillingTransactions);
    try api.get("/batches", handler.listCloudBillingBatches);
    try api.get("/topups", handler.listCloudBillingTopups);
    try api.get("/price-tiers", handler.listCloudBillingPriceTiers);
    try api.post("/checkout-sessions", handler.createCloudBillingCheckoutSession);
    try api.get("/checkout-sessions/:sessionId", handler.getCloudBillingCheckoutSession);
    try api.post("/portal-sessions", handler.createCloudBillingPortalSession);

    try api.get("/invoices", handler.listInvoices);
    try api.get("/invoices/:id", handler.getInvoice);
    try api.get("/subscription", handler.getSubscription);
    try api.get("/usage", handler.listUsage);
    try api.get("/payment-methods", handler.listPaymentMethods);
    try api.get("/billing-details", handler.getBillingDetails);
    try api.patch("/billing-details", handler.updateBillingDetails);
}
