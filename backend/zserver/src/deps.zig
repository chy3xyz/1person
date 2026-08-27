//! Process-wide `zfinal.ConnectionPool` — the single source of truth
//! for the postgres connection pool. Follows the layout in
//! `zfinal/examples/ruoyi-gen/src/deps.zig`.
//!
//! Call `deps.acquire()` / `deps.releaseBack()` directly and use
//! `zfinal.Model` or `zfinal.DB.queryParams`.

const std = @import("std");
const zfinal = @import("zfinal");
const pg_url = @import("pg_url.zig");

const log = std.log.scoped(.deps);

pub var pool: ?*zfinal.ConnectionPool = null;
pub var initialized: bool = false;

/// Initialise the process-wide connection pool. Returns true when a
/// usable pool is ready, false when no DB is available (parse failure,
/// pool init failure, or the initial probe connection failing). Callers
/// that must not degrade (production boot, token verification) use the
/// return value to fail hard instead of silently running without a
/// database.
pub fn initPool(allocator: std.mem.Allocator, db_url: []const u8) bool {
    if (initialized) return pool != null;
    initialized = true;

    const cfg = pg_url.parse(db_url) catch |err| {
        log.warn("failed to parse DATABASE_URL ({s}); running without DB", .{@errorName(err)});
        return false;
    };

    const max_conn: usize = if (cfg.max_connections > 0) @intCast(cfg.max_connections) else 10;
    pool = zfinal.ConnectionPool.init(allocator, cfg, max_conn) catch |err| {
        log.warn("pool init failed ({s}); running without DB", .{@errorName(err)});
        return false;
    };

    if (pool) |p| {
        if (p.acquire()) |probe| {
            p.release(probe) catch {};
            log.info("postgres pool ready (max_connections={d})", .{max_conn});
            return true;
        } else |err| {
            log.warn("could not open initial DB connection ({s}); running without DB", .{@errorName(err)});
            // deinit frees the pool struct itself.
            p.deinit();
            pool = null;
        }
    }
    return false;
}

pub fn deinit(_: std.mem.Allocator) void {
    if (pool) |p| p.deinit();
    pool = null;
}

pub fn acquire() !*zfinal.DB {
    const p = pool orelse return error.PoolNotInitialized;
    return p.acquire();
}

pub fn releaseBack(conn: *zfinal.DB) void {
    if (pool) |p| p.release(conn) catch {};
}

/// Returns true when a connection pool has been initialised (i.e.
/// DATABASE_URL was configured and the pool was created successfully).
/// Use this instead of `model.borrowDb()` for no-DB-vs-DB branching
/// when the result of `acquire()` isn't needed — `borrowDb()` acquires
/// a connection which is then leaked if the branch is entered without
/// releasing it.
pub fn hasPool() bool {
    return pool != null;
}
