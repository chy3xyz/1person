//! Application-level Redis wrapper around zfinal.RedisClient.

const std = @import("std");
const zfinal = @import("zfinal");

const log = std.log.scoped(.redis);

var g_allocator: ?std.mem.Allocator = null;
var g_client: ?*zfinal.RedisClient = null;
/// Endpoint resolved once by `init`; `newConnection` reuses it so a
/// subscriber start never re-parses the URL or hits the resolver.
var g_host: ?[]const u8 = null;
var g_port: u16 = 6379;

pub const Error = error{
    InvalidRedisUrl,
    ConnectionFailed,
    OutOfMemory,
};

pub fn client() ?*zfinal.RedisClient {
    return g_client;
}

/// Parse `redis://host:port` and open the global Redis client.
pub fn init(allocator: std.mem.Allocator, url: []const u8) Error!void {
    if (g_client != null) return;

    const host, const port = try parseRedisUrl(allocator, url);
    errdefer allocator.free(host);

    const client_ptr = try allocator.create(zfinal.RedisClient);
    errdefer allocator.destroy(client_ptr);
    client_ptr.* = zfinal.RedisClient.init(allocator, host, port) catch |err| {
        log.err("failed to init Redis client for {s}:{}: {}", .{ host, port, err });
        return error.ConnectionFailed;
    };
    client_ptr.connect() catch |err| {
        log.err("failed to connect to Redis at {s}:{}: {}", .{ host, port, err });
        client_ptr.deinit();
        return error.ConnectionFailed;
    };

    g_allocator = allocator;
    g_client = client_ptr;
    g_host = host;
    g_port = port;
    log.info("redis connected to {s}:{}", .{ host, port });
}

pub fn deinit() void {
    if (g_client) |c| {
        c.deinit();
        if (g_allocator) |a| a.destroy(c);
    }
    if (g_host) |h| {
        if (g_allocator) |a| a.free(h);
    }
    g_client = null;
    g_allocator = null;
    g_host = null;
    g_port = 6379;
}

/// Create a new standalone Redis connection to the same endpoint as the
/// global client. `connect` needs a `*RedisClient`, so the client is
/// heap-allocated; the caller owns it and must call `deinit()` +
/// `allocator.destroy()`.
pub fn newConnection(allocator: std.mem.Allocator) !?*zfinal.RedisClient {
    const host = g_host orelse return null;
    const port = g_port;

    const client_ptr = try allocator.create(zfinal.RedisClient);
    errdefer allocator.destroy(client_ptr);
    client_ptr.* = try zfinal.RedisClient.init(allocator, host, port);
    client_ptr.connect() catch |err| {
        log.err("redis subscriber connection failed: {}", .{err});
        client_ptr.deinit();
        allocator.destroy(client_ptr);
        return null;
    };
    return client_ptr;
}

fn parseRedisUrl(allocator: std.mem.Allocator, url: []const u8) Error!struct { []const u8, u16 } {
    const prefix = "redis://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidRedisUrl;

    var rest = url[prefix.len..];
    // Skip optional auth (redis://user:pass@host...)
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        rest = rest[at + 1 ..];
    }

    const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..end];

    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidRedisUrl;
        return .{ try resolveIp4(allocator, authority[0..colon], port), port };
    } else {
        return .{ try resolveIp4(allocator, authority, 6379), 6379 };
    }
}

/// Return `host` as a dotted-quad IPv4 literal, resolving it if needed.
///
/// `zfinal.RedisClient.connect` calls `IpAddress.parseIp4(self.host, ...)`,
/// which only accepts a literal. Handing it a name — `localhost`, or a
/// compose/k8s service name — fails with `error.InvalidCharacter` before a
/// socket is ever opened, so the documented `REDIS_URL=redis://localhost:6379`
/// would silently degrade the server to "continuing without Redis".
/// Resolving here keeps hostnames working without touching zfinal.
fn resolveIp4(allocator: std.mem.Allocator, host: []const u8, port: u16) Error![]const u8 {
    if (std.Io.net.IpAddress.parseIp4(host, port)) |_| {
        return allocator.dupe(u8, host);
    } else |_| {}

    const HostName = std.Io.net.HostName;
    const io = zfinal.io_instance.io;
    const name = HostName.init(host) catch return error.InvalidRedisUrl;

    // `lookup` is documented as non-blocking when the queue holds at least
    // 16 entries, so it can run inline instead of on an async frame. It
    // closes the queue before returning.
    var buffer: [32]HostName.LookupResult = undefined;
    var queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);
    name.lookup(io, &queue, .{ .port = port, .family = .ip4 }) catch return error.InvalidRedisUrl;

    while (queue.getOneUncancelable(io)) |result| {
        const addr = switch (result) {
            .address => |a| a,
            .canonical_name => continue,
        };
        const ip4 = switch (addr) {
            .ip4 => |v4| v4,
            .ip6 => continue,
        };
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
            ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
        });
    } else |err| switch (err) {
        error.Closed => {},
    }

    return error.InvalidRedisUrl;
}

/// GET key. Caller owns the returned value if non-null.
pub fn get(key: []const u8) !?[]const u8 {
    const c = g_client orelse return null;
    return c.get(key);
}

/// SET key value with a TTL in seconds.
pub fn setEx(key: []const u8, value: []const u8, ttl_seconds: u32) !void {
    const c = g_client orelse return;
    try c.setEx(key, value, ttl_seconds);
}

/// DEL key.
pub fn del(key: []const u8) !void {
    const c = g_client orelse return;
    try c.del(key);
}

/// PUBLISH channel message. Returns the number of clients that received it.
pub fn publish(channel: []const u8, message: []const u8) !i64 {
    const c = g_client orelse return 0;
    return c.publish(channel, message);
}

/// SUBSCRIBE channel.
pub fn subscribe(channel: []const u8) !void {
    const c = g_client orelse return;
    try c.subscribe(channel);
}
