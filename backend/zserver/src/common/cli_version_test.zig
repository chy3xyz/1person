//! Regression coverage for the daemon CLI version gate.
//!
//! The gate decides whether a daemon may serve a quick-create task. It
//! runs in two places — the frontend modal pre-check and the server
//! handler — so the two implementations must classify the same strings
//! the same way. These tests pin the classification rules the frontend
//! mirror in `frontend/packages/core/runtimes/cli-version.ts`.
//!
//! The case that actually bit us: this fork has no release tags, so
//! `git describe --tags --always --dirty` prints a bare commit hash
//! (`e22060811-dirty`). Upstream's exemption only recognises the
//! *tagged* describe shape (`v0.2.15-235-gdaf0e935`), so every local
//! build looked "missing" and the modal refused to submit — while the
//! daemon was perfectly capable.

const std = @import("std");
const testing = std.testing;
const cli_version = @import("cli_version.zig");

const floor = cli_version.min_quick_create_cli_version;

test "a release at or above the floor passes" {
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion(floor, floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("v0.1.0", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("0.4.2", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("1.0.0", floor));
}

test "a release below the floor is too_old" {
    try testing.expectEqual(cli_version.VersionState.too_old, cli_version.checkMinCliVersion("v0.0.9", floor));
    try testing.expectEqual(cli_version.VersionState.too_old, cli_version.checkMinCliVersion("0.0.1", floor));
}

test "an unreported or unparsable version fails closed" {
    try testing.expectEqual(cli_version.VersionState.missing, cli_version.checkMinCliVersion("", floor));
    try testing.expectEqual(cli_version.VersionState.missing, cli_version.checkMinCliVersion("   ", floor));
    try testing.expectEqual(cli_version.VersionState.missing, cli_version.checkMinCliVersion("not-a-version", floor));
    // A bare semver prefix without all three components is unparsable.
    try testing.expectEqual(cli_version.VersionState.missing, cli_version.checkMinCliVersion("v1.2", floor));
}

test "a tagged git-describe build passes regardless of the base tag" {
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("v0.2.15-235-gdaf0e935", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("v0.2.15-235-gdaf0e935-dirty", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("0.1.0-1-gabc1234", floor));
}

test "an untagged git-describe build passes — this fork has no release tags" {
    // `git describe --tags --always --dirty` on a tagless checkout.
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("e22060811", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("e22060811-dirty", floor));
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("0a1b2c3d4e5f6071", floor));
}

test "a bare semver is not mistaken for an untagged commit hash" {
    // "0.1.0" starts with one hex character, not seven — it must be
    // classified by the semver rules, not exempted as a dev build.
    try testing.expectEqual(cli_version.VersionState.ok, cli_version.checkMinCliVersion("0.1.0", floor));
    try testing.expectEqual(cli_version.VersionState.too_old, cli_version.checkMinCliVersion("0.0.1", floor));
    // Six hex characters is too short to be a commit hash.
    try testing.expectEqual(cli_version.VersionState.missing, cli_version.checkMinCliVersion("abcdef", floor));
}

test "parseSemver reads the first three numeric components" {
    try testing.expectEqual([3]u32{ 0, 2, 21 }, cli_version.parseSemver("0.2.21").?);
    try testing.expectEqual([3]u32{ 0, 2, 21 }, cli_version.parseSemver("v0.2.21").?);
    try testing.expectEqual([3]u32{ 2, 1, 5 }, cli_version.parseSemver("2.1.5 (Claude Code)").?);
    try testing.expect(cli_version.parseSemver("dev") == null);
    try testing.expect(cli_version.parseSemver("v1.2") == null);
}
