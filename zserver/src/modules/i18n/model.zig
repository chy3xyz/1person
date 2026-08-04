//! I18n module — data layer.
//!
//! Pure in-memory module: no DB access at all. All translations and
//! locale configs live in service.zig's StringHashMap stores. The
//! structs here define the JSON shapes returned by the API.

const std = @import("std");

/// A single translation entry keyed by (locale, key).
pub const Translation = struct {
    locale: []const u8,
    key: []const u8,
    value: []const u8,
};

/// Locale configuration — which locales are available and enabled.
pub const LocaleConfig = struct {
    locale: []const u8,
    name: []const u8,
    enabled: bool,
};

/// Request body for PUT / POST to set a single translation entry.
pub const SetTranslationRequest = struct {
    locale: []const u8,
    key: []const u8,
    value: []const u8,
};
