//! Contact module — business logic.
//!
//! Stores inbound contact-sales submissions in memory for inspection
//! (the `mem_submissions` list), or in the `contact_sales_inquiry`
//! table when a DB is available. `g_cfg` is preserved from the legacy
//! handler for parity even though the current code path doesn't read
//! it — keeping it makes the migration a true 1:1 move.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const SqlParam = zfinal.SqlParam;
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const validation = @import("../../common/validation.zig");

const log = std.log.scoped(.contact_service);

/// Process-wide config pointer. The legacy handler set this in `init`
/// but never read it; preserved here for migration parity.
var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_submissions: ?std.ArrayList(model.ContactEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn ensureSubmissions() !void {
    if (mem_submissions == null) {
        mem_submissions = std.ArrayList(model.ContactEntry).empty;
    }
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try model.rfc3339(memAlloc(), secs);
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

pub fn contactSales(ctx: *zfinal.Context) !void {
    const parsed = try validation.validateJson(model.ContactSalesRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name orelse "", &std.ascii.whitespace);
    const email = std.mem.trim(u8, req.email orelse "", &std.ascii.whitespace);
    const message = std.mem.trim(u8, req.message orelse "", &std.ascii.whitespace);
    if (name.len == 0 or email.len == 0 or message.len == 0) {
        try response.err(ctx, .bad_request, "name, email, and message are required", 40021);
        return;
    }

    const company = if (req.company) |c| std.mem.trim(u8, c, &std.ascii.whitespace) else "";

    if (deps.acquire() catch null) |db| {
        defer deps.releaseBack(db);
        // Map the simple {name, email, company, message} request to the wider
        // `contact_sales_inquiry` table. first_name gets the whole name and
        // last_name is a placeholder; company_name, company_size, country,
        // region, use_case, goals all fall back to sensible defaults.
        const first_name = name;
        const last_name = "-";
        const business_email = email;
        const company_name = if (company.len > 0) company else "-";
        const company_size = "unknown";
        const country_region = "unknown";
        const use_case = "contact_sales";
        const goals = message;
        var rs = try db.queryParams(
            "INSERT INTO contact_sales_inquiry (first_name, last_name, business_email, " ++
                "company_name, company_size, country_region, use_case, goals, " ++
                "consent_outreach, consent_updates) " ++
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, true, false) " ++
                "RETURNING id::text",
            &[_]SqlParam{
                .{ .text = first_name },
                .{ .text = last_name },
                .{ .text = business_email },
                .{ .text = company_name },
                .{ .text = company_size },
                .{ .text = country_region },
                .{ .text = use_case },
                .{ .text = goals },
            },
        );
        defer rs.deinit();
        const id = if (rs.rows.items.len > 0) (rs.rows.items[0].getText(0) orelse "") else "";
        log.info("contact sales submission from {s} <{s}> (db)", .{ name, email });
        try response.ok(ctx, .{ .success = true, .id = id });
        return;
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureSubmissions();

    const entry = model.ContactEntry{
        .id = try model.generateId(memAlloc(), "contact"),
        .name = try memDup(name),
        .email = try memDup(email),
        .company = if (company.len > 0) try memDup(company) else null,
        .message = try memDup(message),
        .created_at = try nowString(),
    };
    try mem_submissions.?.append(memAlloc(), entry);

    log.info("contact sales submission from {s} <{s}>", .{ entry.name, entry.email });
    try response.ok(ctx, .{ .success = true, .id = entry.id });
}
