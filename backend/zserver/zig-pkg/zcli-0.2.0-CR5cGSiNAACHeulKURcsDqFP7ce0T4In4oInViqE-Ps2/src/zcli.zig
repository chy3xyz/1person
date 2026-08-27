//! zcli - A comptime-driven, type-safe CLI framework for Zig.

const std = @import("std");

pub const ParseError = @import("error.zig").ParseError;
pub const Diagnostic = @import("error.zig").Diagnostic;
pub const style = @import("style.zig");
pub const command = @import("command.zig");
pub const parser = @import("parser.zig");
pub const help = @import("help.zig");

pub fn parse(comptime Cmd: type, args: []const []const u8, allocator: std.mem.Allocator) ParseError!command.Result(Cmd) {
    return parser.parse(Cmd, args, allocator);
}

pub fn free(comptime Cmd: type, value: *const command.Result(Cmd), allocator: std.mem.Allocator) void {
    parser.free(Cmd, value, allocator);
}

pub fn print_help(writer: anytype, comptime Cmd: type) !void {
    return help.print_help(writer, Cmd);
}

pub fn print_usage(writer: anytype, comptime Cmd: type) !void {
    return help.print_usage(writer, Cmd);
}

pub fn print_diagnostic(writer: anytype, diag: Diagnostic) !void {
    return help.print_diagnostic(writer, diag);
}

/// Dispatch a parsed parent command to handler functions.
/// `handlers` must be a struct with one field per subcommand, where each
/// field is a function accepting the subcommand result type.
pub fn execute(comptime Cmd: type, parsed: command.Result(Cmd), handlers: anytype) !void {
    if (command.Result(Cmd) == Cmd) {
        @compileError("execute() is only for parent commands with subcommands");
    }
    switch (parsed.active) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            const handler = @field(handlers, field_name);
            const field_value = @field(parsed.value, field_name);
            try handler(field_value);
        },
    }
}
