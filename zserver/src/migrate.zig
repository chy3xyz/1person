//! `zserver migrate` — apply all SQL files in `server/migrations/` in
//! order, using the process-wide `zfinal.ConnectionPool` (the same pool
//! the HTTP server uses). Bootstrap-on-startup style, since zfinal does
//! not ship a real migration runner.
//
//! - If no DB is available, prints a friendly message and exits 0.
//! - Each `*.up.sql` file is executed inside a transaction; failures
//!   abort the whole transaction so a half-applied migration cannot
//!   leave the schema in an inconsistent state. The exception is files
//!   using `CREATE INDEX CONCURRENTLY`, which PostgreSQL rejects inside
//!   a transaction block — those run unwrapped.
//! - Prints a one-line summary per file.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("deps.zig");

const log = std.log.scoped(.migrate);

const migration_dir_rel = "../../server/migrations";

/// Run the `migrate` command. `db_url` may be null, in which case the
/// command exits 0 after printing a clear "no DB configured" message.
pub fn run(allocator: std.mem.Allocator, db_url: ?[]const u8) !void {
    if (db_url == null or db_url.?.len == 0) {
        std.debug.print("zserver migrate: no DATABASE_URL configured; nothing to do.\n", .{});
        return;
    }

    const dir = migrationsDir(allocator) orelse {
        std.debug.print("zserver migrate: cannot locate server/migrations directory.\n", .{});
        return;
    };
    defer allocator.free(dir);

    const files = try discoverMigrations(allocator, dir);
    if (files.len == 0) {
        std.debug.print("zserver migrate: no .up.sql files found in {s}\n", .{dir});
        return;
    }

    // Stand up the same pool the HTTP server uses, run the migrations,
    // tear it down. The bool result reports pool readiness; the explicit
    // hasPool() check below decides whether to continue.
    _ = deps.initPool(allocator, db_url.?);
    defer deps.deinit(allocator);

    if (!deps.hasPool()) {
        std.debug.print("zserver migrate: cannot connect to database; continuing without DB.\n", .{});
        return;
    }

    var applied: usize = 0;
    var skipped: usize = 0;
    for (files) |file| {
        const content = readFileAlloc(allocator, file.path) catch |err| {
            std.debug.print("zserver migrate: SKIP  {s} (read error: {s})\n", .{ file.name, @errorName(err) });
            skipped += 1;
            continue;
        };
        defer allocator.free(content);

        if (!ensureSchemaMigrationsTable()) {
            std.debug.print("zserver migrate: SKIP  {s} (cannot bootstrap schema_migrations)\n", .{file.name});
            skipped += 1;
            continue;
        }

        if (migrationAlreadyApplied(file.name)) {
            std.debug.print("zserver migrate: SKIP  {s} (already applied)\n", .{file.name});
            skipped += 1;
            continue;
        }

        if (applyMigration(file.name, content)) {
            std.debug.print("zserver migrate: APPLY {s}\n", .{file.name});
            applied += 1;
        } else {
            std.debug.print("zserver migrate: FAIL  {s} (transaction rolled back)\n", .{file.name});
            return;
        }
    }

    std.debug.print("zserver migrate: done. applied={d} skipped={d} total={d}\n", .{ applied, skipped, files.len });
}

const MigrationFile = struct {
    name: []const u8,
    path: []const u8,
};

fn io() std.Io {
    return zfinal.io_instance.io;
}

fn migrationsDir(allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "../../server/migrations",
        "../server/migrations",
        "server/migrations",
    };
    for (candidates) |cand| {
        // iterate=true: discoverMigrations scans the directory. Without it
        // the open succeeds but iteration is Illegal Behavior — tolerated
        // by macOS, but musl returns no entries (containerized migrate
        // found zero migrations).
        if (std.Io.Dir.cwd().openDir(io(), cand, .{ .iterate = true })) |dir| {
            var d = dir;
            d.close(io());
            return allocator.dupe(u8, cand) catch null;
        } else |_| continue;
    }
    return null;
}

fn discoverMigrations(allocator: std.mem.Allocator, dir_rel: []const u8) ![]MigrationFile {
    const dir = std.Io.Dir.cwd().openDir(io(), dir_rel, .{ .iterate = true }) catch |err| {
        log.warn("cannot open migrations dir {s}: {s}", .{ dir_rel, @errorName(err) });
        return &[_]MigrationFile{};
    };
    defer dir.close(io());

    var entries: std.ArrayList(MigrationFile) = .empty;
    defer entries.deinit(allocator);

    var it = dir.iterate();
    while (it.next(io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".up.sql")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_rel, name });
        try entries.append(allocator, MigrationFile{
            .name = try allocator.dupe(u8, name),
            .path = path,
        });
    }

    const SortCtx = struct {
        fn less(_: @This(), a: MigrationFile, b: MigrationFile) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };
    std.mem.sort(MigrationFile, entries.items, SortCtx{}, SortCtx.less);
    return try entries.toOwnedSlice(allocator);
}

/// Highest migration version available on disk (from the server/migrations
/// directory), derived from the zero-padded NNN_ filename prefix.
/// Used by the readiness check so the expected version never drifts from
/// the actual migration files — no hardcoded constant to forget to bump.
/// Returns null when the directory cannot be located or no .up.sql
/// files exist.
pub fn latestMigrationVersion(allocator: std.mem.Allocator) ?i64 {
    const dir = migrationsDir(allocator) orelse return null;
    defer allocator.free(dir);

    const files = discoverMigrations(allocator, dir) catch return null;
    defer {
        for (files) |f| {
            allocator.free(f.name);
            allocator.free(f.path);
        }
        allocator.free(files);
    }

    var max_version: i64 = 0;
    for (files) |f| {
        // Filename format: NNN_slug.up.sql — the leading number is the
        // version. Split on '_' so 4+ digit versions keep working.
        var it = std.mem.splitScalar(u8, f.name, '_');
        const num_str = it.next() orelse continue;
        const num = std.fmt.parseInt(i64, num_str, 10) catch continue;
        if (num > max_version) max_version = num;
    }
    return max_version;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());

    const stat = try file.stat(io());
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(io(), &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const n = try rdr.interface.readSliceShort(buf[offset..]);
        if (n == 0) return error.UnexpectedEOF;
        offset += n;
    }
    return buf;
}

fn ensureSchemaMigrationsTable() bool {
    const db = deps.acquire() catch return false;
    defer deps.releaseBack(db);
    db.exec(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\    name        TEXT PRIMARY KEY,
        \\    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        \\)
    ) catch {
        return false;
    };
    return true;
}

fn migrationAlreadyApplied(name: []const u8) bool {
    const db = deps.acquire() catch return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT 1 FROM schema_migrations WHERE name = $1",
        &[_]SqlParam{.{ .text = name }},
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `needle` must be lowercase ASCII.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn applyMigration(name: []const u8, content: []const u8) bool {
    const db = deps.acquire() catch return false;
    defer deps.releaseBack(db);

    // `zfinal.DB.exec/execParams` require a `[:0]const u8` SQL. Build
    // a sentinel-terminated copy of the migration body so we don't
    // have to change the on-disk format.
    const allocator = std.heap.page_allocator;
    const sql_z = allocator.allocSentinel(u8, content.len, 0) catch return false;
    defer allocator.free(sql_z);
    @memcpy(sql_z, content);

    // `CREATE INDEX CONCURRENTLY` is rejected inside a transaction block, so
    // those files run unwrapped. They are the only migrations that can leave
    // partial state behind on failure — PostgreSQL marks the half-built index
    // INVALID and a re-run drops/recreates it (every such file uses
    // `IF NOT EXISTS` or an explicit `DROP INDEX IF EXISTS` preamble).
    const concurrent = containsIgnoreCase(content, "concurrently");

    if (!concurrent) db.exec("BEGIN") catch return false;

    // Migration bodies are multi-statement scripts. The extended protocol
    // (`execParams`) rejects those with 42601, so use the simple protocol.
    db.exec(sql_z) catch |err| {
        log.err("migration {s} failed: {s}", .{ name, @errorName(err) });
        if (!concurrent) db.exec("ROLLBACK") catch {};
        return false;
    };

    db.execParams(
        "INSERT INTO schema_migrations (name) VALUES ($1) ON CONFLICT (name) DO NOTHING",
        &[_]SqlParam{.{ .text = name }},
    ) catch {
        if (!concurrent) db.exec("ROLLBACK") catch {};
        return false;
    };

    if (!concurrent) db.exec("COMMIT") catch {
        db.exec("ROLLBACK") catch {};
        return false;
    };
    return true;
}
