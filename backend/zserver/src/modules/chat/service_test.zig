//! Regression coverage for the chat_session queries.
//!
//! The chat queries read a boolean `has_unread` column, but no migration
//! ever created one: the schema (migration 040) tracks unread state in
//! `unread_since TIMESTAMPTZ`. Every chat endpoint that touched the column
//! answered 500 with PostgreSQL 42703 "column has_unread does not exist",
//! which left the console's chat panel and agent task list empty.
//!
//! These tests run against a live PostgreSQL and skip themselves when
//! `DATABASE_URL` is unset, so `zig build test` still works on a bare
//! checkout.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const service = @import("service.zig");

/// `std.process.Environ` can only be built from the block handed to
/// `std.process.Init`, which a test binary never receives. libc is linked,
/// so fall back to `getenv(3)`.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn testDb() !?*zfinal.DB {
    if (!deps.hasPool()) {
        const url = std.mem.span(getenv("DATABASE_URL") orelse return null);
        if (url.len == 0) return null;
        _ = deps.initPool(std.heap.page_allocator, url);
        if (!deps.hasPool()) return null;
    }
    return deps.acquire() catch null;
}

test "chat session columns resolve against the live schema" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    // The exact column list every chat endpoint selects. A column that no
    // migration creates fails here with 42703.
    var rs = try db.queryParams(
        "SELECT " ++ service.chatSessionColumns ++ " FROM chat_session WHERE workspace_id = $1::uuid LIMIT 1",
        &[_]zfinal.SqlParam{.{ .text = "00000000-0000-0000-0000-000000000000" }},
    );
    defer rs.deinit();

    // An empty result is fine — the point is that the query runs at all.
}

test "chat session unread marker is derived, not a stored column" {
    // `unread_since` is the stored marker (migration 040); `has_unread` is
    // derived from it. Reading a stored `has_unread` column is what broke.
    try std.testing.expect(
        std.mem.indexOf(u8, service.chatSessionColumns, "unread_since IS NOT NULL") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, service.chatSessionColumns, "status, has_unread") == null,
    );
}
