//! I18n module — business logic.
//!
//! Pure in-memory, no-DB module. Translations are stored in a
//! StringHashMap keyed by "locale:key". LocaleConfig entries are
//! fixed at startup (zh, en) and are immutable at runtime.
//!
//! handler.zig is a thin delegate; data shapes live in model.zig.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_translations: ?std.StringHashMap([]const u8) = null;
// Pre-configured locale list.
var mem_locales_initialized: bool = false;
var mem_locales: [2]model.LocaleConfig = undefined;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInitLocales() void {
    if (mem_locales_initialized) return;
    mem_locales_initialized = true;
    mem_locales = [2]model.LocaleConfig{
        .{ .locale = "zh", .name = "中文", .enabled = true },
        .{ .locale = "en", .name = "English", .enabled = true },
    };
}

fn memInitTranslations() !void {
    if (mem_translations == null) {
        mem_translations = std.StringHashMap([]const u8).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

/// GET /api/i18n/translations?locale=<locale>
/// Returns all translations for the given locale as an array of
/// Translation objects.
pub fn getTranslations(ctx: *zfinal.Context) !void {
    const locale = if (ctx.getPara("locale") catch null) |loc| loc else {
        // Return empty list when no locale param is provided.
        var list: std.ArrayList(model.Translation) = .empty;
        defer list.deinit(ctx.allocator);
        try ctx.renderJson(.{ .translations = list.items, .total = @as(usize, 0) });
        return;
    };

    try memInitTranslations();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const prefix_len = locale.len + 1; // "locale:"
    var list: std.ArrayList(model.Translation) = .empty;
    defer list.deinit(ctx.allocator);

    var it = mem_translations.?.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.len < prefix_len) continue;
        if (!std.mem.startsWith(u8, kv.key_ptr.*, locale)) continue;
        if (kv.key_ptr.*.len == locale.len) continue; // exact match without ':'
        if (kv.key_ptr.*[locale.len] != ':') continue;
        const translation_key = kv.key_ptr.*[prefix_len..];
        try list.append(ctx.allocator, model.Translation{
            .locale = locale,
            .key = translation_key,
            .value = kv.value_ptr.*,
        });
    }

    try ctx.renderJson(.{ .translations = list.items, .total = list.items.len });
}

/// POST /api/i18n/translations
/// Body: { "locale": "en", "key": "greeting", "value": "Hello" }
pub fn setTranslation(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(model.SetTranslationRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.locale.len == 0) {
        try response.err(ctx, .bad_request, "locale is required", 40001);
        return;
    }
    if (req.key.len == 0) {
        try response.err(ctx, .bad_request, "key is required", 40002);
        return;
    }
    if (req.value.len == 0) {
        try response.err(ctx, .bad_request, "value is required", 40003);
        return;
    }

    try memInitTranslations();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const composite_key = try std.fmt.allocPrint(memAlloc(), "{s}:{s}", .{ req.locale, req.key });
    errdefer memAlloc().free(composite_key);

    try mem_translations.?.put(composite_key, try memDup(req.value));

    try response.ok(ctx, model.Translation{
        .locale = try memDup(req.locale),
        .key = try memDup(req.key),
        .value = try memDup(req.value),
    });
}

/// GET /api/i18n/locales
/// Returns the fixed list of available locale configurations.
pub fn listLocales(ctx: *zfinal.Context) !void {
    memInitLocales();
    // Allocate a copy on ctx.allocator so the response borrows
    // request-lifetime memory.
    var list: std.ArrayList(model.LocaleConfig) = .empty;
    defer list.deinit(ctx.allocator);
    for (&mem_locales) |lc| {
        try list.append(ctx.allocator, lc);
    }
    try ctx.renderJson(.{ .locales = list.items, .total = list.items.len });
}
