//! Billing module — business logic.
//!
//! Owns the in-memory billing state for the no-DB smoke path. Exposes
//! the HTTP-facing operations mirroring the legacy handler. The
//! `handler.zig` is a thin delegate; data structs live in `model.zig`.
//!
//! Note: this is a "dummy" partial migration — the route
//! registration in `routes.zig` is a shim that delegates to the
//! legacy `src/routes/billing.zig` and `src/routes/cloud_billing.zig`,
//! which still own the actual HTTP wiring for this turn. Future
//! turns can replace the shim with a direct registration that uses
//! the new `handler` functions.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const model = @import("model.zig");

const log = std.log.scoped(.billing_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_initialized = false;

var mem_invoices: ?std.StringHashMap(std.ArrayList(model.InvoiceEntry)) = null;
var mem_subscriptions: ?std.StringHashMap(model.SubscriptionEntry) = null;
var mem_usage: ?std.StringHashMap(std.ArrayList(model.UsageEntry)) = null;
var mem_payment_methods: ?std.StringHashMap(std.ArrayList(model.PaymentMethodEntry)) = null;
var mem_billing_details: ?std.StringHashMap(model.BillingDetailsEntry) = null;
var mem_checkout_sessions: ?std.StringHashMap(model.CheckoutSessionEntry) = null;
var mem_portal_sessions: ?std.StringHashMap(model.PortalSessionEntry) = null;
var mem_transactions: ?std.StringHashMap(std.ArrayList(model.TransactionEntry)) = null;
var mem_topups: ?std.StringHashMap(std.ArrayList(model.TopupEntry)) = null;
var mem_batches: ?std.StringHashMap(std.ArrayList(model.BatchEntry)) = null;
var mem_price_tiers: ?std.ArrayList(model.PriceTierEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_initialized) return;
    mem_invoices = std.StringHashMap(std.ArrayList(model.InvoiceEntry)).init(memAlloc());
    mem_subscriptions = std.StringHashMap(model.SubscriptionEntry).init(memAlloc());
    mem_usage = std.StringHashMap(std.ArrayList(model.UsageEntry)).init(memAlloc());
    mem_payment_methods = std.StringHashMap(std.ArrayList(model.PaymentMethodEntry)).init(memAlloc());
    mem_billing_details = std.StringHashMap(model.BillingDetailsEntry).init(memAlloc());
    mem_checkout_sessions = std.StringHashMap(model.CheckoutSessionEntry).init(memAlloc());
    mem_portal_sessions = std.StringHashMap(model.PortalSessionEntry).init(memAlloc());
    mem_transactions = std.StringHashMap(std.ArrayList(model.TransactionEntry)).init(memAlloc());
    mem_topups = std.StringHashMap(std.ArrayList(model.TopupEntry)).init(memAlloc());
    mem_batches = std.StringHashMap(std.ArrayList(model.BatchEntry)).init(memAlloc());

    var tiers: std.ArrayList(model.PriceTierEntry) = .empty;
    try tiers.append(memAlloc(), model.PriceTierEntry{
        .id = try memDup("tier_free"),
        .name = try memDup("Free"),
        .price_cents = 0,
        .currency = try memDup("usd"),
        .interval = try memDup("month"),
        .description = try memDup("Individual experimentation with limited requests."),
        .requests_included = 100,
    });
    try tiers.append(memAlloc(), model.PriceTierEntry{
        .id = try memDup("tier_pro"),
        .name = try memDup("Pro"),
        .price_cents = 2000,
        .currency = try memDup("usd"),
        .interval = try memDup("month"),
        .description = try memDup("Small teams with moderate usage."),
        .requests_included = 10_000,
    });
    try tiers.append(memAlloc(), model.PriceTierEntry{
        .id = try memDup("tier_team"),
        .name = try memDup("Team"),
        .price_cents = 9900,
        .currency = try memDup("usd"),
        .interval = try memDup("month"),
        .description = try memDup("Growing teams with shared workspaces."),
        .requests_included = 100_000,
    });
    try tiers.append(memAlloc(), model.PriceTierEntry{
        .id = try memDup("tier_enterprise"),
        .name = try memDup("Enterprise"),
        .price_cents = 0,
        .currency = try memDup("usd"),
        .interval = try memDup("year"),
        .description = try memDup("Custom volume pricing and support."),
        .requests_included = 1_000_000,
    });
    mem_price_tiers = tiers;

    mem_initialized = true;
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn rfc3339(allocator: std.mem.Allocator, ts: i64) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const sd = epoch.getDaySeconds();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1,
        sd.getHoursIntoDay(), sd.getMinutesIntoHour(), sd.getSecondsIntoMinute(),
    });
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try rfc3339(memAlloc(), secs);
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn getAccountKey(ctx: *zfinal.Context) []const u8 {
    return ctx.attributes.get("user_id") orelse "default";
}

fn ensureAccountDataLocked(account_key: []const u8) !void {
    const allocator = memAlloc();
    const now_ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();

    if (mem_subscriptions.?.get(account_key) == null) {
        const start_ts = now_ts - 15 * 24 * 60 * 60;
        const end_ts = now_ts + 15 * 24 * 60 * 60;
        const sub = model.SubscriptionEntry{
            .status = try memDup("active"),
            .plan_id = try memDup("tier_team"),
            .plan_name = try memDup("Team"),
            .price_cents = 9900,
            .currency = try memDup("usd"),
            .interval = try memDup("month"),
            .current_period_start = try rfc3339(allocator, start_ts),
            .current_period_end = try rfc3339(allocator, end_ts),
            .cancel_at_period_end = false,
            .seats = 5,
        };
        try mem_subscriptions.?.put(try memDup(account_key), sub);
    }

    if (mem_billing_details.?.get(account_key) == null) {
        const details = model.BillingDetailsEntry{
            .name = try memDup("Example Account"),
            .email = try memDup("billing@example.com"),
            .address_line1 = try memDup("123 Market St"),
            .address_line2 = null,
            .city = try memDup("San Francisco"),
            .state = try memDup("CA"),
            .postal_code = try memDup("94105"),
            .country = try memDup("US"),
            .tax_id = null,
        };
        try mem_billing_details.?.put(try memDup(account_key), details);
    }

    if (mem_payment_methods.?.get(account_key) == null) {
        var list: std.ArrayList(model.PaymentMethodEntry) = .empty;
        try list.append(allocator, model.PaymentMethodEntry{
            .id = try generateId(allocator, "pm"),
            .type = try memDup("card"),
            .brand = try memDup("visa"),
            .last4 = try memDup("4242"),
            .exp_month = 12,
            .exp_year = 2030,
            .is_default = true,
        });
        try mem_payment_methods.?.put(try memDup(account_key), list);
    }

    if (mem_invoices.?.get(account_key) == null) {
        var list: std.ArrayList(model.InvoiceEntry) = .empty;
        const inv_id = try generateId(allocator, "inv");
        const due_ts = now_ts + 7 * 24 * 60 * 60;
        try list.append(allocator, model.InvoiceEntry{
            .id = inv_id,
            .number = try std.fmt.allocPrint(allocator, "INV-{s}", .{inv_id[0..8]}),
            .status = try memDup("open"),
            .amount_due = 9900,
            .amount_paid = 0,
            .currency = try memDup("usd"),
            .created_at = try rfc3339(allocator, now_ts),
            .due_at = try rfc3339(allocator, due_ts),
            .paid_at = null,
            .pdf_url = null,
            .description = try memDup("Monthly Team plan"),
        });
        try mem_invoices.?.put(try memDup(account_key), list);
    }

    if (mem_usage.?.get(account_key) == null) {
        var list: std.ArrayList(model.UsageEntry) = .empty;
        var day: i64 = 29;
        while (day >= 0) : (day -= 1) {
            const day_ts = now_ts - @as(i64, @intCast(day)) * 24 * 60 * 60;
            try list.append(allocator, model.UsageEntry{
                .date = try rfc3339(allocator, day_ts),
                .requests = 100 + @rem(day_ts, 500),
                .tokens = 1000 + @rem(day_ts, 5000),
                .cost_cents = 10 + @rem(day_ts, 50),
            });
        }
        try mem_usage.?.put(try memDup(account_key), list);
    }

    if (mem_transactions.?.get(account_key) == null) {
        var list: std.ArrayList(model.TransactionEntry) = .empty;
        try list.append(allocator, model.TransactionEntry{
            .id = try generateId(allocator, "txn"),
            .type = try memDup("charge"),
            .amount_cents = 9900,
            .currency = try memDup("usd"),
            .status = try memDup("succeeded"),
            .description = try memDup("Team plan monthly charge"),
            .created_at = try rfc3339(allocator, now_ts),
        });
        try mem_transactions.?.put(try memDup(account_key), list);
    }

    if (mem_topups.?.get(account_key) == null) {
        var list: std.ArrayList(model.TopupEntry) = .empty;
        try list.append(allocator, model.TopupEntry{
            .id = try generateId(allocator, "top"),
            .amount_cents = 5000,
            .currency = try memDup("usd"),
            .status = try memDup("succeeded"),
            .created_at = try rfc3339(allocator, now_ts - 2 * 24 * 60 * 60),
        });
        try mem_topups.?.put(try memDup(account_key), list);
    }

    if (mem_batches.?.get(account_key) == null) {
        var list: std.ArrayList(model.BatchEntry) = .empty;
        try list.append(allocator, model.BatchEntry{
            .id = try generateId(allocator, "bat"),
            .status = try memDup("completed"),
            .total_requests = 1234,
            .total_cost_cents = 123,
            .currency = try memDup("usd"),
            .created_at = try rfc3339(allocator, now_ts - 1 * 24 * 60 * 60),
        });
        try mem_batches.?.put(try memDup(account_key), list);
    }
}

pub fn getCloudBillingBalance(ctx: *zfinal.Context) !void {
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    var balance: i64 = 12_500;
    if (mem_topups.?.get(account_key)) |topups| {
        for (topups.items) |t| {
            if (std.mem.eql(u8, t.status, "succeeded")) balance += t.amount_cents;
        }
    }
    if (mem_transactions.?.get(account_key)) |txns| {
        for (txns.items) |t| {
            if (std.mem.eql(u8, t.status, "succeeded")) balance -= t.amount_cents;
        }
    }

    try ctx.renderJson(.{ .balance = balance, .currency = "usd" });
}

pub fn listCloudBillingTransactions(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_transactions.?.get(account_key) orelse std.ArrayList(model.TransactionEntry).empty;
    var list: std.ArrayList(model.TransactionEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| try list.append(allocator, e);
    try ctx.renderJson(.{ .transactions = list.items, .total = list.items.len });
}

pub fn listCloudBillingBatches(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_batches.?.get(account_key) orelse std.ArrayList(model.BatchEntry).empty;
    var list: std.ArrayList(model.BatchEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| try list.append(allocator, e);
    try ctx.renderJson(.{ .batches = list.items, .total = list.items.len });
}

pub fn listCloudBillingTopups(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_topups.?.get(account_key) orelse std.ArrayList(model.TopupEntry).empty;
    var list: std.ArrayList(model.TopupEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| try list.append(allocator, e);
    try ctx.renderJson(.{ .topups = list.items, .total = list.items.len });
}

pub fn listCloudBillingPriceTiers(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const tiers = mem_price_tiers.?;
    var list: std.ArrayList(model.PriceTierEntry) = .empty;
    defer list.deinit(allocator);
    for (tiers.items) |t| try list.append(allocator, t);
    try ctx.renderJson(.{ .tiers = list.items, .total = list.items.len });
}

pub fn createCloudBillingCheckoutSession(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateCheckoutSessionRequest);
    defer parsed.deinit();

    const session_id = try generateId(allocator, parsed.value.tier_id orelse "tier");
    const now = try nowString();
    const cfg = g_cfg.?;
    const url = if (cfg.public_url.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/billing/checkout?session={s}", .{ cfg.public_url, session_id })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(url);

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = model.CheckoutSessionEntry{
        .id = try memDup(session_id),
        .status = try memDup("open"),
        .url = try memDup(url),
        .account_key = try memDup(account_key),
        .tier_id = if (parsed.value.tier_id) |t| try memDup(t) else null,
        .customer_email = if (parsed.value.customer_email) |e| try memDup(e) else null,
        .created_at = now,
    };
    try mem_checkout_sessions.?.put(try memDup(session_id), entry);

    try ctx.renderJson(.{
        .session_id = session_id,
        .url = url,
    });
}

pub fn getCloudBillingCheckoutSession(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };
    if (!isValidStripeSessionID(session_id)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid session_id" });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_checkout_sessions.?.get(session_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "session not found" });
        return;
    };

    try ctx.renderJson(.{
        .session_id = entry.id,
        .status = entry.status,
        .url = entry.url,
        .tier_id = entry.tier_id,
        .customer_email = entry.customer_email,
        .created_at = entry.created_at,
    });
}

pub fn createCloudBillingPortalSession(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    const parsed = try ctx.parseJsonBody(model.CreatePortalSessionRequest);
    defer parsed.deinit();

    const session_id = try generateId(allocator, parsed.value.return_url orelse "portal");
    const now = try nowString();
    const cfg = g_cfg.?;
    const url = if (cfg.public_url.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/billing/portal?session={s}", .{ cfg.public_url, session_id })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(url);

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = model.PortalSessionEntry{
        .id = try memDup(session_id),
        .status = try memDup("open"),
        .url = try memDup(url),
        .account_key = try memDup(account_key),
        .return_url = if (parsed.value.return_url) |r| try memDup(r) else null,
        .created_at = now,
    };
    try mem_portal_sessions.?.put(try memDup(session_id), entry);

    try ctx.renderJson(.{
        .session_id = session_id,
        .url = url,
    });
}

pub fn listInvoices(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_invoices.?.get(account_key) orelse std.ArrayList(model.InvoiceEntry).empty;
    var list: std.ArrayList(model.InvoiceEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| try list.append(allocator, e);
    try ctx.renderJson(.{ .invoices = list.items, .total = list.items.len });
}

pub fn getInvoice(ctx: *zfinal.Context) !void {
    try memInit();
    const account_key = getAccountKey(ctx);
    const id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invoice id is required" });
        return;
    };

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_invoices.?.get(account_key) orelse std.ArrayList(model.InvoiceEntry).empty;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.id, id)) {
            try ctx.renderJson(e);
            return;
        }
    }
    ctx.res_status = .not_found;
    try ctx.renderJson(.{ .@"error" = "invoice not found" });
}

pub fn getSubscription(ctx: *zfinal.Context) !void {
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const sub = mem_subscriptions.?.get(account_key) orelse model.SubscriptionEntry{
        .status = "",
        .plan_id = "",
        .plan_name = "",
        .price_cents = 0,
        .currency = "",
        .interval = "",
        .current_period_start = "",
        .current_period_end = "",
        .cancel_at_period_end = false,
        .seats = 0,
    };
    try ctx.renderJson(sub);
}

pub fn listUsage(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_usage.?.get(account_key) orelse std.ArrayList(model.UsageEntry).empty;
    var total_requests: i64 = 0;
    var total_cost_cents: i64 = 0;
    var list: std.ArrayList(model.UsageEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| {
        try list.append(allocator, e);
        total_requests += e.requests;
        total_cost_cents += e.cost_cents;
    }
    try ctx.renderJson(.{
        .usage = list.items,
        .total = list.items.len,
        .total_requests = total_requests,
        .total_cost_cents = total_cost_cents,
    });
}

pub fn listPaymentMethods(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const entries = mem_payment_methods.?.get(account_key) orelse std.ArrayList(model.PaymentMethodEntry).empty;
    var list: std.ArrayList(model.PaymentMethodEntry) = .empty;
    defer list.deinit(allocator);
    for (entries.items) |e| try list.append(allocator, e);
    try ctx.renderJson(.{ .payment_methods = list.items, .total = list.items.len });
}

pub fn getBillingDetails(ctx: *zfinal.Context) !void {
    try memInit();
    const account_key = getAccountKey(ctx);
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const details = mem_billing_details.?.get(account_key) orelse model.BillingDetailsEntry{
        .name = "",
        .email = "",
        .address_line1 = null,
        .address_line2 = null,
        .city = null,
        .state = null,
        .postal_code = null,
        .country = null,
        .tax_id = null,
    };
    try ctx.renderJson(details);
}

pub fn updateBillingDetails(ctx: *zfinal.Context) !void {
    try memInit();
    const account_key = getAccountKey(ctx);
    const parsed = try ctx.parseJsonBody(model.UpdateBillingDetailsRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureAccountDataLocked(account_key);

    const ptr = mem_billing_details.?.getPtr(account_key) orelse unreachable;
    if (req.name) |v| ptr.name = try memDup(v);
    if (req.email) |v| ptr.email = try memDup(v);
    if (req.address_line1) |v| ptr.address_line1 = if (v.len > 0) try memDup(v) else null;
    if (req.address_line2) |v| ptr.address_line2 = if (v.len > 0) try memDup(v) else null;
    if (req.city) |v| ptr.city = if (v.len > 0) try memDup(v) else null;
    if (req.state) |v| ptr.state = if (v.len > 0) try memDup(v) else null;
    if (req.postal_code) |v| ptr.postal_code = if (v.len > 0) try memDup(v) else null;
    if (req.country) |v| ptr.country = if (v.len > 0) try memDup(v) else null;
    if (req.tax_id) |v| ptr.tax_id = if (v.len > 0) try memDup(v) else null;

    try ctx.renderJson(ptr.*);
}

fn isValidStripeSessionID(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}
