# zcli

[![Zig Version](https://img.shields.io/badge/Zig-0.17-orange.svg?logo=zig)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

A comptime-driven, type-safe CLI framework for Zig 0.17.

**Why zcli?** Define commands as plain Zig structs. Fields become flags or positional arguments; nested structs become subcommands. The parser is pure and testable: it returns narrow errors instead of calling `std.process.exit`.

## Installation

### 1. Fetch the package

```sh
zig fetch --save=zcli https://github.com/chy3xyz/zcli/archive/v0.2.0.tar.gz
```

This adds an entry to your `build.zig.zon`:

```zig
.{
    .dependencies = .{
        .zcli = .{
            .url = "https://github.com/chy3xyz/zcli/archive/v0.2.0.tar.gz",
            .hash = "<zig-will-fill-this>",
        },
    },
}
```

### 2. Add the module import

In your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_dep.module("zcli"));

    b.installArtifact(exe);
}
```

### 3. Use it in `src/main.zig`

```zig
const std = @import("std");
const zcli = @import("zcli");

const RunCmd = struct {
    //! Run your workflow

    now: bool = false,
    script: []const u8,

    pub const zcli_options = .{
        .now = .{ .help = "Run immediately", .shortcut = "n" },
        .script = .{ .help = "Script to execute" },
    };
};

const VersionCmd = struct {
    //! Show version
};

const Root = struct {
    //! Your dev toolkit CLI

    run: RunCmd,
    version: VersionCmd,
};

fn handle_run(run: RunCmd) !void {
    std.debug.print("Running {s} (now={})\n", .{ run.script, run.now });
}

fn handle_version(_: VersionCmd) !void {
    std.debug.print("myapp 0.1.0\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        try args.append(allocator, arg);
    }

    const parsed = zcli.parse(Root, args.items, allocator) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zcli.free(Root, &parsed, allocator);

    try zcli.execute(Root, parsed, .{
        .run = handle_run,
        .version = handle_version,
    });
}
```

### 4. Run it

```sh
zig build run -- run -n deploy.sh
# Output: Running deploy.sh (now=true)

zig build run -- version
# Output: myapp 0.1.0
```

## Field Options

Add per-field metadata with a `zcli_options` declaration:

```zig
const RunCmd = struct {
    now: bool = false,
    script: []const u8,

    pub const zcli_options = .{
        .now = .{ .help = "Run immediately", .shortcut = "n" },
        .script = .{ .help = "Script to execute" },
    };
};
```

This provides help text and single-character shortcuts like `-n`.

> **Note:** Zig's comptime reflection does not expose doc comments on struct fields, so `zcli_options` is the supported way to attach help text.

## Supported Types

| Type | CLI Form |
|------|----------|
| `bool` | `--verbose` or `-v` |
| `u32`, `i64`, ... | `--count 5` or `--count=5` |
| `f32`, `f64` | `--ratio 1.5` |
| `[]const u8` | `--name alice` or positional `<name>` |
| `?T` | Optional flag/argument |
| `[]const []const u8` | Variadic positional arguments |
| `enum { ... }` | `--level warn` |

## Error Handling

`zcli.parse` returns a narrow error set:

```zig
pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
    MissingPositionalArg,
    TooManyPositionalArgs,
    UnknownCommand,
    DuplicateFlag,
    OutOfMemory,
};
```

The parser never calls `std.process.exit`. Your application decides how to present errors:

```zig
const parsed = zcli.parse(Root, args.items, allocator) catch |err| {
    try zcli.print_diagnostic(writer, .{ .err = err });
    std.process.exit(1);
};
```

## API Overview

- `zcli.parse(Cmd, args, allocator)` — parse arguments into a typed result.
- `zcli.free(Cmd, &result, allocator)` — free heap-allocated fields.
- `zcli.execute(Cmd, result, handlers)` — dispatch parent commands to handler functions.
- `zcli.print_help(writer, Cmd)` — render help.
- `zcli.print_usage(writer, Cmd)` — render usage line.
- `zcli.print_diagnostic(writer, diagnostic)` — render a parse error.

## Testing

```sh
zig build test
```

## Demo

See `examples/demo/` for a complete working CLI.

## Comparison with zli

zcli is inspired by [zli](https://github.com/xcaeser/zli) but takes a different approach:

| | zli | zcli |
|---|-----|------|
| Definition | Builder API | Plain struct + comptime reflection |
| Help text | Doc comments | `zcli_options` declaration |
| Shortcuts | Built-in | `zcli_options.shortcut` |
| Flag access | Runtime lookup | Compile-time typed field access |
| Error handling | `std.process.exit(1)` | Returns `ParseError` |
| Type safety | Runtime union | Compile-time struct fields |

## License

MIT. See [LICENSE](LICENSE).
