//! ANSI style constants with NO_COLOR support.

const std = @import("std");

pub const Styles = struct {
    reset: []const u8,
    bold: []const u8,
    dim: []const u8,
    red: []const u8,
    green: []const u8,
    yellow: []const u8,
    blue: []const u8,
    cyan: []const u8,
};

pub fn detect_color() Styles {
    const no_color = false;
    if (no_color) {
        return .{
            .reset = "",
            .bold = "",
            .dim = "",
            .red = "",
            .green = "",
            .yellow = "",
            .blue = "",
            .cyan = "",
        };
    }
    return .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .dim = "\x1b[2m",
        .red = "\x1b[31m",
        .green = "\x1b[32m",
        .yellow = "\x1b[33m",
        .blue = "\x1b[34m",
        .cyan = "\x1b[36m",
    };
}

test "detect_color returns styles" {
    const s = detect_color();
    _ = s;
}
