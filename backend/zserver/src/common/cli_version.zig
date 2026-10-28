//! Daemon CLI version gate — server side of the quick-create check.
//!
//! Mirrors `frontend/packages/core/runtimes/cli-version.ts`. Both sides
//! must agree by construction: the modal pre-checks the version it reads
//! off the runtime row, and this module is the authoritative re-check on
//! the server. A disagreement shows up as a submission the UI refuses but
//! the API accepts (or worse, the reverse).
//!
//! Policy:
//!   * A development build is always accepted. Upstream exempts the
//!     `git describe --tags --always --dirty` output
//!     (`v0.2.15-235-gdaf0e935`); this fork has no release tags yet, so
//!     the same command prints a bare commit hash (`e22060811-dirty`).
//!     Both shapes mean "built from source, not a released binary".
//!   * A release build must be at least `min_quick_create_cli_version`.
//!   * An empty or unparsable version fails closed — a daemon that does
//!     not report its version cannot be checked against the floor.
//!
//! The version string itself is the shared signal. The 1p CLI sends it
//! at registration (`POST /api/daemon/register`) and the server stores
//! it on the runtime row's `metadata.cli_version`.

const std = @import("std");

/// The first 1person CLI release of THIS fork that can serve a
/// quick-create task.
///
/// Upstream's floor is `0.2.21` — a number in *upstream's* release line.
/// This fork ships its own line, starting at `0.1.0`, and the
/// quick-create protocol is part of its first release, so the floor
/// lives in the fork's line. Keeping upstream's number here would
/// reject every 1person release the fork ever ships.
pub const min_quick_create_cli_version = "0.1.0";

pub const VersionState = enum {
    /// The version satisfies the floor (or is a development build).
    ok,
    /// Nothing was reported, or the string could not be parsed.
    missing,
    /// Parsed, but below the floor.
    too_old,
};

/// Classify a daemon-reported CLI version against a floor.
///
/// `minimum` is the version floor to compare against; pass
/// `min_quick_create_cli_version` for the quick-create flow.
pub fn checkMinCliVersion(detected: []const u8, minimum: []const u8) VersionState {
    const d = std.mem.trim(u8, detected, &std.ascii.whitespace);
    if (d.len == 0) return .missing;
    if (isDevBuild(d)) return .ok;
    const parsed = parseSemver(d) orelse return .missing;
    const min = parseSemver(minimum) orelse return .missing;
    if (lessThan(parsed, min)) return .too_old;
    return .ok;
}

/// Extract the first three numeric components of a version string.
///
/// Accepts the shapes the ecosystem actually produces: `0.2.21`,
/// `v0.2.21`, `0.2.21 (Claude Code)`.
pub fn parseSemver(raw: []const u8) ?[3]u32 {
    var rest = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];

    var parts: [3]u32 = undefined;
    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        var value: u32 = 0;
        var digits: usize = 0;
        while (digits < rest.len and rest[digits] >= '0' and rest[digits] <= '9') : (digits += 1) {
            value = value * 10 + (rest[digits] - '0');
        }
        if (digits == 0) return null;
        parts[idx] = value;
        rest = rest[digits..];
        if (idx < 2) {
            if (rest.len == 0 or rest[0] != '.') return null;
            rest = rest[1..];
        }
    }
    return parts;
}

fn lessThan(a: [3]u32, b: [3]u32) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    if (a[1] != b[1]) return a[1] < b[1];
    return a[2] < b[2];
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// True for the version strings a source build produces.
///
/// Two shapes count:
///   * tagged   — `v0.2.15-235-gdaf0e935` (`-dirty` suffix allowed):
///     a checkout that has release tags.
///   * untagged — `e22060811-dirty`: a checkout with no tags at all,
///     where `git describe --always` falls back to the commit hash.
///     This fork has no release tags yet, so every local build lands
///     here.
fn isDevBuild(raw: []const u8) bool {
    if (isTaggedDescribe(raw)) return true;
    return isUntaggedDescribe(raw);
}

/// `v?<major>.<minor>.<patch>-<distance>-g<hash>` (+ optional `-dirty`).
fn isTaggedDescribe(raw: []const u8) bool {
    var rest = raw;
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];

    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        var digits: usize = 0;
        while (digits < rest.len and rest[digits] >= '0' and rest[digits] <= '9') : (digits += 1) {}
        if (digits == 0) return false;
        rest = rest[digits..];
        if (idx < 2) {
            if (rest.len == 0 or rest[0] != '.') return false;
            rest = rest[1..];
        }
    }

    if (rest.len == 0 or rest[0] != '-') return false;
    rest = rest[1..];

    var distance: usize = 0;
    while (distance < rest.len and rest[distance] >= '0' and rest[distance] <= '9') : (distance += 1) {}
    if (distance == 0) return false;
    rest = rest[distance..];

    if (rest.len < 2 or rest[0] != '-' or rest[1] != 'g') return false;
    rest = rest[2..];

    var hash: usize = 0;
    while (hash < rest.len and isHexDigit(rest[hash])) : (hash += 1) {}
    if (hash == 0) return false;
    rest = rest[hash..];

    if (rest.len == 0) return true;
    return std.mem.eql(u8, rest, "-dirty");
}

/// `<hash>` (+ optional `-dirty`) — the no-tag `git describe --always`
/// fallback. A commit hash is at least 7 hex characters, which keeps a
/// bare semver like `0.1.0` (one leading hex char) out of this branch.
fn isUntaggedDescribe(raw: []const u8) bool {
    var rest = raw;
    var hash: usize = 0;
    while (hash < rest.len and isHexDigit(rest[hash])) : (hash += 1) {}
    if (hash < 7 or hash > 40) return false;
    rest = rest[hash..];
    if (rest.len == 0) return true;
    return std.mem.eql(u8, rest, "-dirty");
}
