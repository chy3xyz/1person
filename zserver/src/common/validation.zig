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
