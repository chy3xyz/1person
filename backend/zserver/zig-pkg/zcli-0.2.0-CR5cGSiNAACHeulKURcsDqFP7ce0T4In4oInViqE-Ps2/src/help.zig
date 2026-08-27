//! Help, usage, and diagnostic rendering.

const std = @import("std");
const command = @import("command.zig");
const Error = @import("error.zig");
const style = @import("style.zig");

const ParseError = Error.ParseError;
const Diagnostic = Error.Diagnostic;

fn is_flag(comptime field_type: type) bool {
    return !command.is_struct(field_type) and
        field_type != []const u8 and
        field_type != []const []const u8 and
        !(@typeInfo(field_type) == .optional and
          @typeInfo(field_type).optional.child == []const u8);
}

fn is_positional(comptime field_type: type) bool {
    return !command.is_struct(field_type) and !is_flag(field_type);
}

fn flag_display_len(comptime Cmd: type, comptime field_name: []const u8) usize {
    var len = field_name.len + 2; // "--" + name
    const shortcut = command.field_shortcut(Cmd, field_name);
    if (shortcut) |s| {
        len += s.len + 4; // "-s, "
    }
    return len;
}

fn comptime_max_len(comptime Cmd: type) usize {
    const info = @typeInfo(Cmd).@"struct";
    var max_len: usize = 0;
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime command.is_struct(field_type)) {
            const sub_len = comptime_max_len(field_type);
            if (sub_len > max_len) max_len = sub_len;
        } else {
            const len = flag_display_len(Cmd, name);
            if (len > max_len) max_len = len;
        }
    }
    return max_len;
}

fn write_spaces(writer: anytype, count: usize) !void {
    for (0..count) |_| {
        try writer.print(" ", .{});
    }
}

pub fn print_help(writer: anytype, comptime Cmd: type) !void {
    const info = @typeInfo(Cmd).@"struct";
    const s = style.detect_color();
    const max_len = comptime_max_len(Cmd);
    const padding = 5;

    try writer.print("{s}{s}{s}\n\n", .{ s.bold, @typeName(Cmd), s.reset });

    try writer.print("Usage: {s}", .{@typeName(Cmd)});

    var has_subcommands = false;
    var has_flags = false;
    inline for (info.field_types) |field_type| {
        if (comptime command.is_struct(field_type)) has_subcommands = true;
        if (comptime is_flag(field_type)) has_flags = true;
    }
    if (has_subcommands) try writer.print(" [command]", .{});
    if (has_flags) try writer.print(" [options]", .{});
    try writer.print("\n", .{});

    if (has_subcommands) {
        try writer.print("\nCommands:\n", .{});
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime command.is_struct(field_type)) {
                const width = padding + max_len - name.len;
                try writer.print("   {s}", .{name});
                try write_spaces(writer, width);
                try writer.print("\n", .{});
            }
        }
    }

    if (has_flags) {
        try writer.print("\nFlags:\n", .{});
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime !is_flag(field_type)) continue;
            const display_len = flag_display_len(Cmd, name);
            const width = padding + max_len - display_len;
            const shortcut = comptime command.field_shortcut(Cmd, name);
            const help_text = comptime command.field_help(Cmd, name);
            try writer.print("   ", .{});
            if (shortcut) |sc| {
                try writer.print("-{s}, ", .{sc});
            }
            try writer.print("--{s}", .{name});
            try write_spaces(writer, width);
            try writer.print("{s}\n", .{help_text});
        }
    }
}

pub fn print_usage(writer: anytype, comptime Cmd: type) !void {
    const info = @typeInfo(Cmd).@"struct";
    try writer.print("Usage: {s}", .{@typeName(Cmd)});
    var has_subcommands = false;
    var has_flags = false;
    inline for (info.field_types) |field_type| {
        if (comptime command.is_struct(field_type)) has_subcommands = true;
        if (comptime is_flag(field_type)) has_flags = true;
    }
    if (has_subcommands) try writer.print(" [command]", .{});
    if (has_flags) try writer.print(" [options]", .{});
    try writer.print("\n", .{});
}

pub fn print_diagnostic(writer: anytype, diag: Diagnostic) !void {
    const s = style.detect_color();
    try writer.print("{s}error{s}: {s}\n", .{ s.red, s.reset, @errorName(diag.err) });
    if (diag.flag) |name| {
        try writer.print("  flag: --{s}\n", .{name});
    }
    if (diag.expected) |text| {
        try writer.print("  expected: {s}\n", .{text});
    }
    if (diag.got) |text| {
        try writer.print("  got: {s}\n", .{text});
    }
}

test "print_help outputs command name" {
    const Cmd = struct { verbose: bool = false };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try print_help(buf.writer(), Cmd);
    try std.testing.expect(buf.items.len > 0);
}

test "print_help renders shortcut" {
    const Cmd = struct {
        verbose: bool = false,
        pub const zcli_options = .{
            .verbose = .{ .shortcut = "v" },
        };
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try print_help(buf.writer(), Cmd);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "-v, --verbose") != null);
}
