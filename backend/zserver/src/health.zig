//! Health and readiness checks.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("deps.zig");
const migrate_mod = @import("migrate.zig");

const log = std.log.scoped(.health);

pub fn live(ctx: *zfinal.Context) !void {
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .status = "ok" });
}

/// The applied schema version, read from the same table `zserver migrate`
/// writes to.
///
/// `migrate.zig` stores the migration file name without its `.up.sql`
/// suffix in the `version` column (e.g. "119_user_created_at_index"), so
/// the numeric prefix carries the version. `split_part` yields text, which
/// reads back safely regardless of the wire format; the prefix is
/// zero-padded on disk, and lpad keeps the ordering numeric even if that
/// padding width ever changes.
const applied_version_query =
    "SELECT split_part(version, '_', 1) FROM schema_migrations " ++
    "ORDER BY lpad(split_part(version, '_', 1), 10, '0') DESC LIMIT 1";

/// Highest migration version applied to the database, or null when no
/// migration has been applied yet.
pub fn appliedMigrationVersion(db: *zfinal.DB) !?i64 {
    var rs = try db.query(applied_version_query);
    defer rs.deinit();

    if (rs.rows.items.len == 0) return null;
    const version_str = rs.rows.items[0].getText(0) orelse return error.InvalidMigrationVersion;
    return std.fmt.parseInt(i64, version_str, 10) catch return error.InvalidMigrationVersion;
}

pub fn ready(ctx: *zfinal.Context) !void {
    const db = deps.acquire() catch {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "database_unavailable" });
        return;
    };
    defer deps.releaseBack(db);

    const applied = appliedMigrationVersion(db) catch |err| {
        if (err == error.InvalidMigrationVersion) {
            ctx.res_status = .service_unavailable;
            try ctx.renderJson(.{ .status = "not_ready", .reason = "invalid_migration_version" });
        } else {
            log.warn("readyz migration query failed: {}", .{err});
            ctx.res_status = .service_unavailable;
            try ctx.renderJson(.{ .status = "not_ready", .reason = "migration_query_failed" });
        }
        return;
    };

    const version = applied orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "no_migrations" });
        return;
    };

    // Expected version comes from the migration files on disk, not a
    // hardcoded constant — the check can never drift from the actual
    // migration set. When the directory can't be located (e.g. the binary
    // was deployed without server/migrations), fail closed: a readiness
    // probe that can't determine the expected schema is not ready.
    const expected_version = migrate_mod.latestMigrationVersion(ctx.allocator) orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "migrations_dir_unavailable" });
        return;
    };

    if (version < expected_version) {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{
            .status = "not_ready",
            .reason = "migration_behind",
            .current_version = version,
            .expected_version = expected_version,
        });
        return;
    }

    ctx.res_status = .ok;
    try ctx.renderJson(.{
        .status = "ready",
        .migration_version = version,
    });
}
