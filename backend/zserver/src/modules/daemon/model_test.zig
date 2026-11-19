//! Regression coverage for the runtime liveness sweeper.
//!
//! A daemon that dies without deregistering leaves its runtime row marked
//! online: nothing in the register/deregister pair runs, so the status
//! column keeps saying "online" forever. The workspace then shows a machine
//! that nobody can reach, and the UI queues work that no daemon will pick
//! up.
//!
//! Liveness is therefore decided by the age of the heartbeat the daemon
//! writes (`agent_runtime.last_seen_at`), and the sweeper flips the rows
//! whose heartbeat went stale.
//!
//! These tests run against a live PostgreSQL and skip themselves when
//! `DATABASE_URL` is unset, so `zig build test` still works on a bare
//! checkout.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const model = @import("model.zig");

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

/// A scratch workspace every runtime row in this file hangs off.
///
/// The id comes from the database so repeated runs never collide, and the
/// row is removed again when the test finishes.
fn scratchWorkspace(db: *zfinal.DB, allocator: std.mem.Allocator) ![]const u8 {
    const sql = "INSERT INTO workspace (name, slug) " ++
        "VALUES ('sweeper test', 'sweeper-test-' || substr(md5(random()::text), 1, 8)) " ++
        "RETURNING id::text";
    var rs = db.queryParams(sql, &[_]zfinal.SqlParam{}) catch return error.WorkspaceInsertFailed;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.WorkspaceInsertFailed;
    return try allocator.dupe(u8, rs.rows.items[0].getText(0) orelse "");
}

/// Insert a runtime row with a controlled heartbeat age.
///
/// `stale` picks the heartbeat: an hour old, fresh, or never recorded.
fn insertRuntime(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    name: []const u8,
    stale: enum { old, fresh, never },
) ![]const u8 {
    const heartbeat = switch (stale) {
        .old => "now() - interval '1 hour'",
        .fresh => "now()",
        .never => "NULL",
    };
    const sql = try std.fmt.allocPrintSentinel(
        allocator,
        "INSERT INTO agent_runtime (workspace_id, name, runtime_mode, provider, status, last_seen_at) " ++
            "VALUES ($1::uuid, $2, 'local', 'local', 'online', {s}) RETURNING id::text",
        .{heartbeat},
        0,
    );
    defer allocator.free(sql);
    var rs = db.queryParams(sql, &[_]zfinal.SqlParam{
        .{ .text = workspace_id },
        .{ .text = name },
    }) catch return error.RuntimeInsertFailed;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return error.RuntimeInsertFailed;
    return try allocator.dupe(u8, rs.rows.items[0].getText(0) orelse "");
}

/// Remove the scratch workspace (its runtime rows cascade with it).
fn dropWorkspace(db: *zfinal.DB, workspace_id: []const u8) void {
    _ = db.execParams(
        "DELETE FROM workspace WHERE id = $1::uuid",
        &[_]zfinal.SqlParam{.{ .text = workspace_id }},
    ) catch {};
}

fn runtimeStatus(db: *zfinal.DB, allocator: std.mem.Allocator, runtime_id: []const u8) ![]const u8 {
    const sql = "SELECT status FROM agent_runtime WHERE id = $1::uuid";
    var rs = try db.queryParams(sql, &[_]zfinal.SqlParam{.{ .text = runtime_id }});
    defer rs.deinit();
    // The row was just inserted — a missing row means the query did not
    // see it, which is a failure, not a reason to skip.
    if (rs.rows.items.len == 0) return error.RuntimeRowMissing;
    return try allocator.dupe(u8, rs.rows.items[0].getText(0) orelse "");
}

test "the sweeper marks a runtime whose heartbeat went stale as offline" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);
    const allocator = std.testing.allocator;

    const workspace_id = try scratchWorkspace(db, allocator);
    defer allocator.free(workspace_id);
    defer dropWorkspace(db, workspace_id);
    const runtime_id = try insertRuntime(db, allocator, workspace_id, "stale", .old);
    defer allocator.free(runtime_id);

    const swept = model.sweepStaleRuntimes(allocator);
    defer swept.deinit(allocator);

    const status = try runtimeStatus(db, allocator, runtime_id);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("offline", status);

    // The workspace has to hear about it: a status that changed in the
    // database but never reaches the clients leaves the workspace
    // showing a machine that is gone.
    try std.testing.expect(swept.count >= 1);
    var announced = false;
    for (swept.workspace_ids) |ws| {
        if (std.mem.eql(u8, ws, workspace_id)) announced = true;
    }
    try std.testing.expect(announced);
}

test "the sweeper leaves a runtime with a fresh heartbeat alone" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);
    const allocator = std.testing.allocator;

    const workspace_id = try scratchWorkspace(db, allocator);
    defer allocator.free(workspace_id);
    defer dropWorkspace(db, workspace_id);
    const runtime_id = try insertRuntime(db, allocator, workspace_id, "fresh", .fresh);
    defer allocator.free(runtime_id);

    const swept = model.sweepStaleRuntimes(allocator);
    defer swept.deinit(allocator);

    const status = try runtimeStatus(db, allocator, runtime_id);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("online", status);
}

test "the sweeper leaves a runtime that never reported a heartbeat alone" {
    // An installed desktop app ships its own CLI, and the server is
    // upgraded independently: a daemon from before the heartbeat column
    // was written never fills it in. Declaring such a runtime dead would
    // strand a machine that is working fine.
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);
    const allocator = std.testing.allocator;

    const workspace_id = try scratchWorkspace(db, allocator);
    defer allocator.free(workspace_id);
    defer dropWorkspace(db, workspace_id);
    const runtime_id = try insertRuntime(db, allocator, workspace_id, "legacy", .never);
    defer allocator.free(runtime_id);

    const swept = model.sweepStaleRuntimes(allocator);
    defer swept.deinit(allocator);

    const status = try runtimeStatus(db, allocator, runtime_id);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("online", status);
}

test "a heartbeat brings a runtime the sweeper marked offline back online" {
    // The sweeper and the heartbeat are two halves of one truth. A
    // daemon that survives the freshness window — a laptop that was
    // asleep, a network that was partitioned — has to be able to report
    // in again. If the heartbeat only stamped the timestamp, the row
    // would stay offline for good and the UI (which offers online
    // runtimes only) would keep hiding a machine that is right there.
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);
    const allocator = std.testing.allocator;

    const workspace_id = try scratchWorkspace(db, allocator);
    defer allocator.free(workspace_id);
    defer dropWorkspace(db, workspace_id);
    const runtime_id = try insertRuntime(db, allocator, workspace_id, "slept", .old);
    defer allocator.free(runtime_id);

    const swept = model.sweepStaleRuntimes(allocator);
    defer swept.deinit(allocator);
    const status_after_sweep = try runtimeStatus(db, allocator, runtime_id);
    defer allocator.free(status_after_sweep);
    try std.testing.expectEqualStrings("offline", status_after_sweep);

    _ = model.heartbeatRuntime(runtime_id);

    const status = try runtimeStatus(db, allocator, runtime_id);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("online", status);
}
