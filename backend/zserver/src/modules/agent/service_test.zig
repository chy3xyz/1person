//! Regression coverage for the agent task snapshot query.
//!
//! The query references its workspace id as `$1` in both UNION branches,
//! but it used to bind that placeholder twice. PostgreSQL's extended query
//! protocol binds one value per placeholder, so the query failed with
//! "bind message supplies 2 parameters, but prepared statement requires 1"
//! and `/api/agent-task-snapshot` answered 500 on every call.
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

/// Count the distinct bind placeholders (`$1`, `$2`, …) in a SQL string.
fn distinctPlaceholderCount(sql: []const u8) usize {
    var seen = [_]bool{ false, false, false, false, false, false, false, false };
    var count: usize = 0;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        if (sql[i] != '$') continue;
        i += 1;
        if (i >= sql.len or sql[i] < '1' or sql[i] > '8') continue;
        const idx = sql[i] - '1';
        if (!seen[idx]) {
            seen[idx] = true;
            count += 1;
        }
    }
    return count;
}

test "agent task snapshot binds one value per placeholder" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    // The workspace id is referenced by both UNION branches, so the query
    // has exactly one placeholder and must be bound exactly once.
    try std.testing.expectEqual(@as(usize, 1), distinctPlaceholderCount(service.agentTaskSnapshotSql));

    // Bind through the same helper the handler uses: a regression that
    // binds the reused placeholder twice fails here with "bind message
    // supplies 2 parameters, but prepared statement requires 1".
    var param_buf: [1]zfinal.SqlParam = undefined;
    const params = service.agentTaskSnapshotParams(
        "00000000-0000-0000-0000-000000000000",
        &param_buf,
    );
    try std.testing.expectEqual(
        distinctPlaceholderCount(service.agentTaskSnapshotSql),
        params.len,
    );

    var rs = try db.queryParams(service.agentTaskSnapshotSql, params);
    defer rs.deinit();

    // An empty result is fine — the point is that the query binds and runs.
}
