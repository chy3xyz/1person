//! Integration tests for PostgreSQL binary-format decoding.
//!
//! zfinal's postgres driver issues queries with `result_format = 1`, so every
//! value arrives in its native binary encoding. Types without an explicit
//! decoder used to be handed back as raw bytes wrapped in a text cell, which
//! produced mojibake in JSON responses and `22021 invalid byte sequence` when
//! a value was echoed back to the server. `uuid`, `timestamptz` and `jsonb`
//! account for 300+ columns in this schema, so the decoding is load-bearing
//! and worth pinning down.
//!
//! These tests need a live PostgreSQL and skip themselves when `DATABASE_URL`
//! is unset, so `zig build test` still works on a bare checkout.

const std = @import("std");
const deps = @import("deps.zig");

/// Bring up the shared pool once for the whole file. Returns null (and the
/// caller skips) when no database is configured.
/// `std.process.Environ` can only be built from the block handed to
/// `std.process.Init`, which a test binary never receives. libc is linked, so
/// fall back to `getenv(3)`.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn testDb() !?*@import("zfinal").DB {
    if (!deps.hasPool()) {
        const url = std.mem.span(getenv("DATABASE_URL") orelse return null);
        if (url.len == 0) return null;
        deps.initPool(std.heap.page_allocator, url);
        if (!deps.hasPool()) return null;
    }
    return deps.acquire() catch null;
}

/// Run `SELECT <expr>` and compare the single text cell against `expected`.
fn expectSelect(sql: [:0]const u8, expected: []const u8) !void {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    var rs = try db.query(sql);
    defer rs.deinit();

    try std.testing.expectEqual(@as(usize, 1), rs.rows.items.len);
    const got = rs.rows.items[0].getText(0) orelse return error.UnexpectedNull;
    // A decoder that silently fell through to the raw-bytes path shows up here
    // as invalid UTF-8 long before the string comparison would explain why.
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualStrings(expected, got);
}

test "uuid decodes to canonical hyphenated form" {
    try expectSelect(
        "SELECT '550e8400-e29b-41d4-a716-446655440000'::uuid",
        "550e8400-e29b-41d4-a716-446655440000",
    );
}

test "uuid round-trips through a text comparison" {
    // The original failure mode: a uuid read back as raw bytes could not be
    // used as a parameter without tripping 22021.
    try expectSelect(
        "SELECT ('550e8400-e29b-41d4-a716-446655440000'::uuid)::text",
        "550e8400-e29b-41d4-a716-446655440000",
    );
}

test "timestamptz decodes to RFC 3339 UTC" {
    // Input carries an explicit offset so the result does not depend on the
    // session TimeZone.
    try expectSelect(
        "SELECT '2026-07-31 06:40:40.5149+00'::timestamptz",
        "2026-07-31T06:40:40.5149Z",
    );
}

test "timestamptz normalises a non-UTC offset to UTC" {
    try expectSelect(
        "SELECT '2026-07-31 14:40:40+08'::timestamptz",
        "2026-07-31T06:40:40Z",
    );
}

test "timestamptz omits a zero fractional part" {
    try expectSelect(
        "SELECT '2000-01-01 00:00:00+00'::timestamptz",
        "2000-01-01T00:00:00Z",
    );
}

test "timestamptz handles dates before the PostgreSQL epoch" {
    try expectSelect(
        "SELECT '1970-01-01 00:00:00+00'::timestamptz",
        "1970-01-01T00:00:00Z",
    );
}

test "timestamptz infinity is preserved" {
    try expectSelect("SELECT 'infinity'::timestamptz", "infinity");
    try expectSelect("SELECT '-infinity'::timestamptz", "-infinity");
}

test "timestamp without time zone carries no suffix" {
    try expectSelect(
        "SELECT '2026-07-31 06:40:40'::timestamp",
        "2026-07-31T06:40:40",
    );
}

test "date decodes to ISO calendar date" {
    try expectSelect("SELECT '2026-07-31'::date", "2026-07-31");
    try expectSelect("SELECT '1999-12-31'::date", "1999-12-31");
    // Leap day, exercised because the civil-date conversion is easy to get
    // wrong around February in a leap year.
    try expectSelect("SELECT '2024-02-29'::date", "2024-02-29");
}

test "time decodes with trailing zeros trimmed" {
    try expectSelect("SELECT '12:34:56.5'::time", "12:34:56.5");
    try expectSelect("SELECT '00:00:00'::time", "00:00:00");
}

test "jsonb strips the version byte" {
    try expectSelect("SELECT '{\"a\": 1}'::jsonb", "{\"a\": 1}");
}

test "jsonb survives non-ascii content" {
    try expectSelect("SELECT '{\"k\": \"中文\"}'::jsonb", "{\"k\": \"中文\"}");
}

test "json passes through unchanged" {
    try expectSelect("SELECT '{\"a\":1}'::json", "{\"a\":1}");
}

test "numeric renders like PostgreSQL text output" {
    try expectSelect("SELECT 12345.6789::numeric", "12345.6789");
    // dscale forces trailing zeros that the digit groups do not carry.
    try expectSelect("SELECT 1.10::numeric", "1.10");
    try expectSelect("SELECT (-0.0001)::numeric", "-0.0001");
    try expectSelect("SELECT 0::numeric", "0");
    // Value smaller than one base-10000 group, exercising the negative-weight
    // branch of the fractional loop.
    try expectSelect("SELECT 0.00000001::numeric", "0.00000001");
    try expectSelect("SELECT 'NaN'::numeric", "NaN");
}

test "numeric handles many integer groups" {
    try expectSelect(
        "SELECT 123456789012345678901234567890::numeric",
        "123456789012345678901234567890",
    );
}

test "inet decodes ipv4 and hides a full prefix" {
    try expectSelect("SELECT '192.168.1.1'::inet", "192.168.1.1");
    try expectSelect("SELECT '10.0.0.0/8'::inet", "10.0.0.0/8");
}

test "inet decodes ipv6 with zero-run compression" {
    try expectSelect("SELECT '2001:db8::1'::inet", "2001:db8::1");
    try expectSelect("SELECT '::1'::inet", "::1");
}

test "cidr always shows its prefix" {
    try expectSelect("SELECT '192.168.100.0/24'::cidr", "192.168.100.0/24");
}

test "already-cast text columns are unaffected" {
    // Existing call sites that added ::text as a workaround must keep working.
    try expectSelect("SELECT now()::text IS NOT NULL", "true");
}
