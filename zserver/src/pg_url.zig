//! Parse a libpq-style connection URL into a `zfinal.DBConfig`.
//!
//! Supports `postgres://[user[:pass]@]host[:port]/dbname[?opts]`. The
//! returned config borrows from `url`; keep `url` alive for as long as
//! the pool uses the config.

const std = @import("std");
const zfinal = @import("zfinal");

const log = std.log.scoped(.pg_url);

pub const ParseError = error{ InvalidUrl, OutOfMemory, MissingDatabase };

pub fn parse(url: []const u8) ParseError!zfinal.DBConfig {
    const scheme_sep = std.mem.indexOf(u8, url, "://") orelse {
        log.warn("connection string is not a URL; falling back to host=localhost port=5432 db=postgres", .{});
        return zfinal.DBConfig.postgres("postgres", "postgres", "");
    };
    const scheme = url[0..scheme_sep];
    if (!std.mem.eql(u8, scheme, "postgres") and !std.mem.eql(u8, scheme, "postgresql")) {
        log.warn("unknown scheme '{s}'; expected 'postgres'/'postgresql'", .{scheme});
    }
    var rest = url[scheme_sep + 3 ..];

    var query: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "?")) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    var username: []const u8 = "postgres";
    var password: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            username = userinfo[0..colon];
            password = userinfo[colon + 1 ..];
        } else {
            username = userinfo;
        }
    }

    var host: []const u8 = "localhost";
    var port: u16 = 5432;
    var database: []const u8 = "postgres";
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const hostport = rest[0..slash];
        const db = rest[slash + 1 ..];
        if (db.len == 0) return error.MissingDatabase;
        database = db;
        if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| {
            host = hostport[0..colon];
            port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch 5432;
        } else {
            host = hostport;
        }
    }

    var cfg = zfinal.DBConfig{
        .db_type = .postgres,
        .host = host,
        .port = port,
        .database = database,
        .username = username,
        .password = password,
    };

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "connect_timeout")) {
            cfg.timeout = std.fmt.parseInt(u32, v, 10) catch cfg.timeout;
        } else if (std.mem.eql(u8, k, "max_connections")) {
            cfg.max_connections = std.fmt.parseInt(u32, v, 10) catch cfg.max_connections;
        }
    }
    return cfg;
}

test "parse a typical docker URL" {
    const cfg = try parse("postgres://app:secret@db.local:5433/zserver?sslmode=disable&connect_timeout=5");
    try std.testing.expectEqualStrings("db.local", cfg.host.?);
    try std.testing.expectEqual(@as(u16, 5433), cfg.port.?);
    try std.testing.expectEqualStrings("zserver", cfg.database);
    try std.testing.expectEqualStrings("app", cfg.username.?);
    try std.testing.expectEqualStrings("secret", cfg.password.?);
    try std.testing.expectEqual(@as(u32, 5), cfg.timeout);
}

test "parse falls back to defaults for non-URL strings" {
    const cfg = try parse("host=foo port=5432");
    try std.testing.expectEqualStrings("localhost", cfg.host.?);
}
