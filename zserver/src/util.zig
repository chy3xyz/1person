//! Small helpers.

const std = @import("std");

/// Duplicate a slice and append a null terminator. Caller owns result.
pub fn dupeZ(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![:0]u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf.ptr, s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Duplicate a slice and convert ASCII characters to lowercase. Caller owns result.
pub fn dupeLower(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}
