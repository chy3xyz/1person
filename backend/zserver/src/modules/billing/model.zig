//! Billing module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and request DTOs. The in-memory store and
//! business logic live in `service.zig`.
//!
//! Note: this is a "dummy" partial migration — the route
//! registration in `routes.zig` is a shim that delegates to the
//! legacy `src/routes/billing.zig` and `src/routes/cloud_billing.zig`,
//! which still own the actual HTTP wiring for this turn.

const std = @import("std");

// ──────────────────────────────────────────────────────────────────────
// in-memory row types
// ──────────────────────────────────────────────────────────────────────

pub const InvoiceEntry = struct {
    id: []const u8,
    number: []const u8,
    status: []const u8,
    amount_due: i64,
    amount_paid: i64,
    currency: []const u8,
    created_at: []const u8,
    due_at: []const u8,
    paid_at: ?[]const u8,
    pdf_url: ?[]const u8,
    description: ?[]const u8,
};

pub const SubscriptionEntry = struct {
    status: []const u8,
    plan_id: []const u8,
    plan_name: []const u8,
    price_cents: i64,
    currency: []const u8,
    interval: []const u8,
    current_period_start: []const u8,
    current_period_end: []const u8,
    cancel_at_period_end: bool,
    seats: i32,
};

pub const UsageEntry = struct {
    date: []const u8,
    requests: i64,
    tokens: i64,
    cost_cents: i64,
};

pub const PaymentMethodEntry = struct {
    id: []const u8,
    type: []const u8,
    brand: ?[]const u8,
    last4: ?[]const u8,
    exp_month: ?i32,
    exp_year: ?i32,
    is_default: bool,
};

pub const BillingDetailsEntry = struct {
    name: []const u8,
    email: []const u8,
    address_line1: ?[]const u8,
    address_line2: ?[]const u8,
    city: ?[]const u8,
    state: ?[]const u8,
    postal_code: ?[]const u8,
    country: ?[]const u8,
    tax_id: ?[]const u8,
};

pub const CheckoutSessionEntry = struct {
    id: []const u8,
    status: []const u8,
    url: []const u8,
    account_key: []const u8,
    tier_id: ?[]const u8,
    customer_email: ?[]const u8,
    created_at: []const u8,
};

pub const PortalSessionEntry = struct {
    id: []const u8,
    status: []const u8,
    url: []const u8,
    account_key: []const u8,
    return_url: ?[]const u8,
    created_at: []const u8,
};

pub const TransactionEntry = struct {
    id: []const u8,
    type: []const u8,
    amount_cents: i64,
    currency: []const u8,
    status: []const u8,
    description: ?[]const u8,
    created_at: []const u8,
};

pub const TopupEntry = struct {
    id: []const u8,
    amount_cents: i64,
    currency: []const u8,
    status: []const u8,
    created_at: []const u8,
};

pub const BatchEntry = struct {
    id: []const u8,
    status: []const u8,
    total_requests: i64,
    total_cost_cents: i64,
    currency: []const u8,
    created_at: []const u8,
};

pub const PriceTierEntry = struct {
    id: []const u8,
    name: []const u8,
    price_cents: i64,
    currency: []const u8,
    interval: []const u8,
    description: []const u8,
    requests_included: i64,
};

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

pub const CreateCheckoutSessionRequest = struct {
    tier_id: ?[]const u8 = null,
    customer_email: ?[]const u8 = null,
};

pub const CreatePortalSessionRequest = struct {
    return_url: ?[]const u8 = null,
};

pub const UpdateBillingDetailsRequest = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    address_line1: ?[]const u8 = null,
    address_line2: ?[]const u8 = null,
    city: ?[]const u8 = null,
    state: ?[]const u8 = null,
    postal_code: ?[]const u8 = null,
    country: ?[]const u8 = null,
    tax_id: ?[]const u8 = null,
};
