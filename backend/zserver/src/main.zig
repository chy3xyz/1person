//! zserver — Zig rewrite of the 1Person Go server.

const std = @import("std");
const zcli = @import("zcli");
const zfinal = @import("zfinal");
const server = @import("server.zig");
const migrate_mod = @import("migrate.zig");
const build_options = @import("build_options");

const version = build_options.version;
const commit = build_options.commit;

const ServerCmd = struct {
    //! Start the HTTP server.

    port: ?u16 = null,
    db_url: ?[]const u8 = null,

    pub const zcli_options = .{
        .port = .{ .help = "HTTP listen port (env: PORT, default: 8080)" },
        .db_url = .{ .help = "Database URL (env: DATABASE_URL)" },
    };
};

const MigrateCmd = struct {
    //! Apply SQL migrations from backend/zserver/migrations/.

    db_url: ?[]const u8 = null,

    pub const zcli_options = .{
        .db_url = .{ .help = "Database URL (env: DATABASE_URL or ONEPERSON_DATABASE_URL)" },
    };
};

const VersionCmd = struct {
    //! Show version information.
};

const Root = struct {
    //! 1Person server CLI — Zig rewrite.

    server: ServerCmd,
    migrate: MigrateCmd,
    version: VersionCmd,
};

fn handle_server(cmd: ServerCmd, init: std.process.Init) !void {
    try server.run(init.gpa, init.environ_map, .{
        .port = cmd.port,
        .db_url = cmd.db_url,
    });
}

fn handle_migrate(cmd: MigrateCmd, init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    // --db-url flag wins; otherwise fall back to the DATABASE_URL /
    // ONEPERSON_DATABASE_URL env vars (documented in the zcli_options).
    // Reading the env here keeps `zserver migrate` usable in containers
    // and CI without an explicit flag.
    const db_url = cmd.db_url orelse
        init.environ_map.get("DATABASE_URL") orelse
        init.environ_map.get("ONEPERSON_DATABASE_URL");
    try migrate_mod.run(allocator, db_url);
}

fn handle_version(_: VersionCmd) !void {
    std.debug.print("zserver {s} (commit: {s})\n", .{ version, commit });
}

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);

    const allocator = init.gpa;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        try args.append(allocator, arg);
    }

    const parsed = zcli.parse(Root, args.items, allocator) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zcli.free(Root, &parsed, allocator);

    switch (parsed.active) {
        .server => try handle_server(parsed.value.server, init),
        .migrate => try handle_migrate(parsed.value.migrate, init),
        .version => try handle_version(parsed.value.version),
    }
}
