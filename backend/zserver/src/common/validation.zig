//! Input validation helpers shared by every handler.
//!
//! Mirrors the helpers in `zfinal/examples/ruoyi-gen/src/common/validation.zig`.
//! Each helper returns the validated value and writes a 400 error
//! envelope + returns an error on failure so the caller can `try`
//! it without manually inspecting ctx state.

const std = @import("std");
const zfinal = @import("zfinal");
const response = @import("response.zig");

/// Read a required JSON field of type `[]const u8`. Writes a 400
/// envelope + returns `error.MissingField` when the field is absent,
/// empty, or all whitespace. The caller passes the parsed body and
/// the field name; we trim and return the non-empty slice.
pub fn requireField(ctx: *zfinal.Context, body: anytype, field_name: []const u8) ![]const u8 {
    const raw = @field(body, field_name);
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        try response.err(ctx, .bad_request, "missing field", 40020);
        return error.MissingField;
    }
    return trimmed;
}

/// Same as `requireField` but for `?T` (optional) fields. Returns
/// the unwrapped value, `null` if the field is absent / empty, or
/// writes a 400 envelope if the field is present but the value is
/// not the expected `T`.
pub fn optionalField(comptime T: type, body: anytype, field_name: []const u8) ?T {
    const raw = @field(body, field_name);
    if (raw.len == 0) return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Validate a minimal `name@domain` email shape. Does NOT perform an
/// MX lookup or any other I/O.
pub fn isValidEmail(email: []const u8) bool {
    const trimmed = std.mem.trim(u8, email, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '@')) |at| {
        return at > 0 and at < trimmed.len - 1;
    }
    return false;
}

/// Convenience wrapper around `parseJsonBody` that translates parse
/// errors into a uniform 400 envelope. Returns the parsed value (or
/// a sentinel struct with `.deinit()` to call on the caller side).
///
/// Usage:
/// ```zig
/// const Req = struct { name: []const u8 };
/// const parsed = try validateJson(Req, ctx);
/// defer parsed.deinit();
/// const req = parsed.value;
/// ```
pub fn validateJson(comptime T: type, ctx: *zfinal.Context) !std.json.Parsed(T) {
    const parsed = ctx.parseJsonBody(T) catch {
        try response.err(ctx, .bad_request, "invalid request body", 40030);
        return error.InvalidRequestBody;
    };
    return parsed;
}

/// Parse the request body ONCE and hand back both the typed request and
/// the raw JSON tree.
///
/// Upstream keeps the raw JSON around for one reason: a PATCH field has
/// three states — absent (leave the column alone), explicitly `null`
/// (clear it), and a value (write it) — and a typed `?T` collapses the
/// first two into one. Handlers that need to clear a nullable column
/// (the issue assignee pair, for instance) can only tell the three apart
/// by looking at the raw body.
///
/// Both parses read the same body text: the request body may only be
/// consumed once per request.
pub fn validateJsonWithRaw(
    comptime T: type,
    ctx: *zfinal.Context,
    typed: *std.json.Parsed(T),
    raw: *std.json.Parsed(std.json.Value),
) !void {
    const body = ctx.getBodyText() catch {
        try response.err(ctx, .bad_request, "invalid request body", 40030);
        return error.InvalidRequestBody;
    };
    defer ctx.allocator.free(body);

    typed.* = std.json.parseFromSlice(T, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        try response.err(ctx, .bad_request, "invalid request body", 40030);
        return error.InvalidRequestBody;
    };
    raw.* = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{
        .allocate = .alloc_always,
    }) catch {
        typed.deinit();
        try response.err(ctx, .bad_request, "invalid request body", 40030);
        return error.InvalidRequestBody;
    };
}

/// How a field appeared in the raw request body.
///
/// `absent` means "the client did not mention this field" — the column
/// keeps its current value. `explicit_null` means "the client sent
/// `null`" — the column is cleared. `value` means the client sent a
/// value, which the typed request already carries.
pub const FieldState = enum { absent, explicit_null, value };

/// Read the state of one field from the raw JSON tree.
pub fn fieldState(raw: std.json.Value, name: []const u8) FieldState {
    const obj = switch (raw) {
        .object => |o| o,
        else => return .absent,
    };
    const value = obj.get(name) orelse return .absent;
    return switch (value) {
        .null => .explicit_null,
        else => .value,
    };
}

/// Read the state of one field of a nested object (e.g. `updates` inside
/// a batch payload).
pub fn nestedFieldState(raw: std.json.Value, parent: []const u8, name: []const u8) FieldState {
    const obj = switch (raw) {
        .object => |o| o,
        else => return .absent,
    };
    const child = obj.get(parent) orelse return .absent;
    const child_obj = switch (child) {
        .object => |o| o,
        else => return .absent,
    };
    const value = child_obj.get(name) orelse return .absent;
    return switch (value) {
        .null => .explicit_null,
        else => .value,
    };
}
