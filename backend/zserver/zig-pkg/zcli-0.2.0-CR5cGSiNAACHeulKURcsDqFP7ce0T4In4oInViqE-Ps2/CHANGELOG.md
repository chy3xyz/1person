# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.2.0] - 2026-06-14

### Added

- `zcli_options` declaration for per-field help text and single-character shortcuts.
- Shortcut parsing in the argument parser (`-v` maps to `--verbose`).
- Help renderer displays shortcuts when configured.

## [0.1.0] - 2026-06-14

### Added

- Comptime-driven CLI definition via plain Zig structs.
- Type-safe flag parsing for `bool`, integers, floats, `[]const u8`, `enum`, and optional variants.
- Positional argument support: required, optional, and variadic.
- Nested struct subcommands with compile-time dispatch.
- Pure parser that returns narrow errors instead of calling `std.process.exit`.
- Help, usage, and diagnostic rendering.
- Comprehensive test suite using `std.testing.allocator`.
- Working demo CLI under `examples/demo/`.
- Open source documentation: README, LICENSE, CONTRIBUTING, CODE_OF_CONDUCT.
