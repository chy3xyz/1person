//! Regression coverage for the readiness probe's migration check.
//!
//! The probe used to read `schema_migrations.name`, but `zserver migrate`
//! writes the migration file name — minus its `.up.sql` suffix — into the
//! `version` column. The query therefore failed on a fully migrated
//! database and `/readyz` answered 503 `migration_query_failed`: the
//! service never reported ready, no matter how current the schema was.
//!
//! These tests need a live PostgreSQL and skip themselves when
//! `DATABASE_URL` is unset, so `zig build test` still works on a bare
//! checkout.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("deps.zig");
const health = @import("health.zig");
const migrate_mod = @import("migrate.zig");

/// Bring up the shared pool once for the whole file. Returns null (and the
/// caller skips) when no database is configured.
/// `std.process.Environ` can only be built from the block handed to
/// `std.process.Init`, which a test binary never receives. libc is linked, so
/// fall back to `getenv(3)`.
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

test "readyz reads the applied version from schema_migrations.version" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    // A database that never ran the migrations has no table to read, so
    // there is nothing to assert about the probe's answer yet.
    var table = db.query("SELECT to_regclass('schema_migrations')::text") catch
        return error.SkipZigTest;
    defer table.deinit();
    if (table.rows.items.len == 0) return error.SkipZigTest;
    if (table.rows.items[0].getText(0) == null) return error.SkipZigTest;

    // The query must not fail — that is the regression: it named a column
    // that does not exist.
    const applied = (try health.appliedMigrationVersion(db)) orelse
        return error.SkipZigTest;

    // The probe reports "ready" once the database is at least as far along
    // as the migration files on disk.
    const expected = migrate_mod.latestMigrationVersion(std.testing.allocator) orelse
        return error.SkipZigTest;
    try std.testing.expect(applied >= expected);
}
