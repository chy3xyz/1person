//! Pure argument parser. No IO, no exit.

const std = @import("std");
const Error = @import("error.zig");
const command = @import("command.zig");

const ParseError = Error.ParseError;
const Allocator = std.mem.Allocator;

fn parse_flag_value(comptime T: type, raw: []const u8) ParseError!T {
    if (T == bool) {
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return error.InvalidFlagValue;
    }
    if (@typeInfo(T) == .int) {
        return std.fmt.parseInt(T, raw, 10) catch return error.InvalidFlagValue;
    }
    if (@typeInfo(T) == .float) {
        return std.fmt.parseFloat(T, raw) catch return error.InvalidFlagValue;
    }
    if (T == []const u8) {
        return raw;
    }
    if (@typeInfo(T) == .@"enum") {
        return std.meta.stringToEnum(T, raw) orelse return error.InvalidFlagValue;
    }
    if (@typeInfo(T) == .optional) {
        return try parse_flag_value(@typeInfo(T).optional.child, raw);
    }
    @compileError("unsupported flag type: " ++ @typeName(T));
}

fn parse_into(comptime Cmd: type, args: *std.ArrayList([]const u8), out: *Cmd, allocator: Allocator) ParseError!void {
    const info = @typeInfo(Cmd).@"struct";

    // Apply defaults.
    inline for (info.field_names, info.field_types, info.field_attrs) |name, field_type, attrs| {
        if (comptime command.is_struct(field_type)) continue;
        if (attrs.default_value_ptr) |ptr| {
            const v: *const field_type = @ptrCast(@alignCast(ptr));
            @field(out, name) = v.*;
        }
    }

    var positionals = std.ArrayList([]const u8).empty;
    defer positionals.deinit(allocator);

    while (args.items.len > 0) {
        const arg = args.items[0];

        if (std.mem.eql(u8, arg, "--")) {
            _ = args.orderedRemove(0);
            while (args.items.len > 0) {
                try positionals.append(allocator, args.orderedRemove(0));
            }
            break;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            const rest = arg[2..];
            const eql_idx = std.mem.indexOf(u8, rest, "=");
            const name = if (eql_idx) |i| rest[0..i] else rest;
            const has_inline_value = eql_idx != null;

            var matched = false;
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (comptime command.is_struct(field_type)) continue;
                if (std.mem.eql(u8, name, field_name)) {
                    const is_bool = comptime field_type == bool or
                        (@typeInfo(field_type) == .optional and
                         @typeInfo(field_type).optional.child == bool);

                    if (is_bool) {
                        if (has_inline_value) {
                            const raw_value = rest[eql_idx.? + 1 ..];
                            @field(out, field_name) = try parse_flag_value(field_type, raw_value);
                        } else {
                            @field(out, field_name) = true;
                        }
                        _ = args.orderedRemove(0);
                    } else {
                        const raw_value = blk: {
                            if (has_inline_value) {
                                break :blk rest[eql_idx.? + 1 ..];
                            } else {
                                if (args.items.len < 2) return error.MissingFlagValue;
                                _ = args.orderedRemove(0);
                                break :blk args.items[0];
                            }
                        };
                        _ = args.orderedRemove(0);
                        @field(out, field_name) = try parse_flag_value(field_type, raw_value);
                    }
                    matched = true;
                }
            }
            if (!matched) return error.UnknownFlag;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            const name = arg[1..];

            var matched = false;
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (comptime command.is_struct(field_type)) continue;
                const shortcut = comptime command.field_shortcut(Cmd, field_name);
                const matches = std.mem.eql(u8, name, field_name) or
                    (shortcut != null and std.mem.eql(u8, name, shortcut.?));
                if (matches) {
                    _ = args.orderedRemove(0);

                    if (comptime field_type == bool or
                        (@typeInfo(field_type) == .optional and
                         @typeInfo(field_type).optional.child == bool))
                    {
                        @field(out, field_name) = true;
                    } else {
                        if (args.items.len == 0) return error.MissingFlagValue;
                        const raw_value = args.orderedRemove(0);
                        @field(out, field_name) = try parse_flag_value(field_type, raw_value);
                    }
                    matched = true;
                }
            }
            if (!matched) return error.UnknownFlag;
        } else {
            try positionals.append(allocator, args.orderedRemove(0));
        }
    }

    // Parse positional args.
    var pos_idx: usize = 0;
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime command.is_struct(field_type)) continue;

        const is_positional = comptime field_type == []const u8 or
            field_type == []const []const u8 or
            (@typeInfo(field_type) == .optional and
             @typeInfo(field_type).optional.child == []const u8);
        if (!is_positional) continue;

        if (comptime field_type == []const []const u8) {
            const slice = try allocator.alloc([]const u8, positionals.items.len - pos_idx);
            for (slice, positionals.items[pos_idx..]) |*s, p| s.* = p;
            @field(out, name) = slice;
            pos_idx = positionals.items.len;
        } else if (comptime @typeInfo(field_type) == .optional) {
            if (pos_idx < positionals.items.len) {
                @field(out, name) = positionals.items[pos_idx];
                pos_idx += 1;
            }
        } else {
            if (pos_idx >= positionals.items.len) return error.MissingPositionalArg;
            @field(out, name) = positionals.items[pos_idx];
            pos_idx += 1;
        }
    }

    if (pos_idx < positionals.items.len) return error.TooManyPositionalArgs;
}

pub fn parse(comptime Cmd: type, raw_args: []const []const u8, allocator: Allocator) ParseError!command.Result(Cmd) {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, raw_args);

    const is_leaf = comptime command.Result(Cmd) == Cmd;

    if (!is_leaf and args.items.len > 0 and !std.mem.startsWith(u8, args.items[0], "-")) {
        const first = args.items[0];
        const info = @typeInfo(Cmd).@"struct";
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime command.is_struct(field_type)) {
                if (std.mem.eql(u8, name, first)) {
                    _ = args.orderedRemove(0);
                    var value: Cmd = undefined;
                    @field(value, name) = try parse(field_type, args.items, allocator);
                    return command.Result(Cmd){
                        .active = @field(std.meta.FieldEnum(Cmd), name),
                        .value = value,
                    };
                }
            }
        }
        return error.UnknownCommand;
    }

    if (comptime !is_leaf) {
        return error.UnknownCommand;
    }

    var result: Cmd = undefined;
    try parse_into(Cmd, &args, &result, allocator);
    return result;
}

pub fn free(comptime Cmd: type, value: *const command.Result(Cmd), allocator: Allocator) void {
    const ResultType = command.Result(Cmd);
    if (ResultType == Cmd) {
        free_cmd(Cmd, @ptrCast(value), allocator);
    } else {
        free_parent(Cmd, value, allocator);
    }
}

fn free_cmd(comptime Cmd: type, value: *const Cmd, allocator: Allocator) void {
    const info = @typeInfo(Cmd).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime command.is_struct(field_type)) {
            free(field_type, &@field(value, name), allocator);
        } else if (comptime field_type == []const []const u8) {
            allocator.free(@field(value, name));
        }
    }
}

fn free_parent(comptime Cmd: type, value: *const command.Result(Cmd), allocator: Allocator) void {
    switch (value.active) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            const FieldType = @TypeOf(@field(value.value, field_name));
            free(FieldType, &@field(value.value, field_name), allocator);
        },
    }
}

test "parse bool flag" {
    const Cmd = struct { verbose: bool = false };
    const result = try parse(Cmd, &.{"--verbose"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqual(true, result);
}

test "parse int flag" {
    const Cmd = struct { count: u32 = 0 };
    const result = try parse(Cmd, &.{"--count", "5"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 5), result);
}

test "unknown flag errors" {
    const Cmd = struct { verbose: bool = false };
    const err = parse(Cmd, &.{"--verboce"}, std.testing.allocator);
    try std.testing.expectError(error.UnknownFlag, err);
}

test "parse subcommand" {
    const RunCmd = struct {
        now: bool = false,
        script: []const u8,
    };
    const Root = struct {
        run: RunCmd,
    };
    const result = try parse(Root, &.{"run", "--now", "deploy.sh"}, std.testing.allocator);
    defer free(Root, &result, std.testing.allocator);
    try std.testing.expectEqualStrings("deploy.sh", result.value.run.script);
    try std.testing.expectEqual(true, result.value.run.now);
}

test "parse positional arg" {
    const Cmd = struct { script: []const u8 };
    const result = try parse(Cmd, &.{"deploy.sh"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqualStrings("deploy.sh", result.script);
}

test "parse optional flag" {
    const Cmd = struct { name: ?[]const u8 = null };
    const result = try parse(Cmd, &.{"--name", "alice"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqualStrings("alice", result.name.?);
}

test "parse enum flag" {
    const Level = enum { debug, info, warn };
    const Cmd = struct { level: Level = .info };
    const result = try parse(Cmd, &.{"--level", "warn"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqual(Level.warn, result.level);
}

test "missing positional arg errors" {
    const Cmd = struct { script: []const u8 };
    const err = parse(Cmd, &.{}, std.testing.allocator);
    try std.testing.expectError(error.MissingPositionalArg, err);
}

test "too many positional args errors" {
    const Cmd = struct { script: []const u8 };
    const err = parse(Cmd, &.{"a", "b"}, std.testing.allocator);
    try std.testing.expectError(error.TooManyPositionalArgs, err);
}

test "parse shortcut flag" {
    const Cmd = struct {
        verbose: bool = false,
        pub const zcli_options = .{
            .verbose = .{ .shortcut = "v" },
        };
    };
    const result = try parse(Cmd, &.{"-v"}, std.testing.allocator);
    defer free(Cmd, &result, std.testing.allocator);
    try std.testing.expectEqual(true, result);
}
