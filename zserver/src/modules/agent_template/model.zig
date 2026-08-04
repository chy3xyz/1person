//! Agent template module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs and request DTOs. The in-memory store and
//! business logic live in `service.zig`.

const std = @import("std");

/// In-memory template entry.
pub const TemplateEntry = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    icon: []const u8,
    category: []const u8,
    config: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Template API response.
pub const TemplateResponse = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    icon: []const u8,
    category: []const u8,
    config: std.json.Value,
};

/// Request DTOs.
pub const CreateTemplateRequest = struct {
    slug: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    category: ?[]const u8 = null,
    config: ?std.json.Value = null,
};

pub const UpdateTemplateRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    category: ?[]const u8 = null,
    config: ?std.json.Value = null,
};

/// Seed templates loaded into the in-memory store on first use.
pub const seed_templates = [_]TemplateEntry{
    .{
        .slug = "software-engineer",
        .name = "Software Engineer",
        .description = "A general-purpose coding assistant.",
        .icon = "code",
        .category = "engineering",
        .config = "{}",
        .created_at = "0",
        .updated_at = "0",
    },
    .{
        .slug = "product-manager",
        .name = "Product Manager",
        .description = "Helps with product planning and prioritization.",
        .icon = "briefcase",
        .category = "product",
        .config = "{}",
        .created_at = "0",
        .updated_at = "0",
    },
    .{
        .slug = "qa-engineer",
        .name = "QA Engineer",
        .description = "Generates test cases and performs QA checks.",
        .icon = "bug",
        .category = "engineering",
        .config = "{}",
        .created_at = "0",
        .updated_at = "0",
    },
};

/// Parse a `config` JSON text into a `std.json.Value`, returning
/// an empty object on parse failure.
pub fn parseConfig(allocator: std.mem.Allocator, text: []const u8, holder: *?std.json.Parsed(std.json.Value)) !std.json.Value {
    if (text.len == 0) return emptyJsonObject();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return emptyJsonObject();
    holder.* = parsed;
    return parsed.value;
}

pub fn emptyJsonObject() std.json.Value {
    return .{ .object = std.json.ObjectMap.empty };
}
