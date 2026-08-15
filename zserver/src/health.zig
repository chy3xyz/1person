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

pub fn ready(ctx: *zfinal.Context) !void {
    const db = deps.acquire() catch {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "database_unavailable" });
        return;
    };
    defer deps.releaseBack(db);

    // schema_migrations is keyed by filename (see migrate.zig), e.g.
    // "119_user_created_at_index.up.sql". Every migration is prefixed with a
    // zero-padded number, so ordering by name is equivalent to ordering by
    // version. split_part yields text, which reads back safely regardless
    // of the wire format.
    var rs = db.query("SELECT split_part(name, '_', 1) FROM schema_migrations ORDER BY name DESC LIMIT 1") catch |err| {
        log.warn("readyz migration query failed: {}", .{err});
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "migration_query_failed" });
        return;
    };
    defer rs.deinit();

    if (rs.rows.items.len == 0) {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "no_migrations" });
        return;
    }

    const version_str = rs.rows.items[0].getText(0) orelse "";
    const version = std.fmt.parseInt(i64, version_str, 10) catch {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .status = "not_ready", .reason = "invalid_migration_version" });
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
