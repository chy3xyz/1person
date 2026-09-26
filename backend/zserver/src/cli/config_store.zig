//! CLI config store: JSON file at ~/.config/1person/config.json (or --path).
//!
//! Shape:
//! {
//!   "server_url": "http://localhost:8080",
//!   "token": "<jwt>",
//!   "daemon_tokens": [ { "workspace_id": "...", "token": "1d_..." } ]
//! }
//! Written with 0600 perms; tokens are secrets.

const std = @import("std");
const zfinal = @import("zfinal");

pub const ConfigFile = struct {
    server_url: []const u8 = "",
    token: []const u8 = "",
    daemon_tokens: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ConfigFile {
        return .{ .daemon_tokens = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *ConfigFile) void {
        const a = self.daemon_tokens.allocator;
        var it = self.daemon_tokens.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.daemon_tokens.deinit();
        a.free(self.server_url);
        a.free(self.token);
    }
};

/// On-disk representation (plain struct so std.json handles it without
/// juggling 0.17's unmanaged ObjectMap).
const TokenPair = struct {
    workspace_id: []const u8,
    token: []const u8,
};

const ConfigDisk = struct {
    server_url: []const u8 = "",
    token: []const u8 = "",
    daemon_tokens: []TokenPair = &.{},
};

/// Resolve the config path: explicit --path wins, else HOME/.config/1person.
pub fn resolvePath(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| return allocator.dupe(u8, p);
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "1person", "config.json" });
}

/// Load config from disk. A missing file yields an empty config (not an error).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ConfigFile {
    var cfg = ConfigFile.init(allocator);
    errdefer cfg.deinit();

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return cfg,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    if (size == 0) return cfg;

    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(io, &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const n = try rdr.interface.readSliceShort(buf[offset..]);
        if (n == 0) break;
        offset += n;
    }

    // Non-leaky parse: Parsed.deinit() frees all parsed allocations
    // (including the daemon_tokens array + strings) after we dupe them out.
    const parsed = std.json.parseFromSlice(ConfigDisk, allocator, buf[0..offset], .{}) catch |err| {
        std.debug.print("warning: cannot parse config {s}: {s}; starting empty\n", .{ path, @errorName(err) });
        return cfg;
    };
    defer parsed.deinit();
    const disk = parsed.value;

    cfg.server_url = try allocator.dupe(u8, disk.server_url);
    cfg.token = try allocator.dupe(u8, disk.token);
    for (disk.daemon_tokens) |p| {
        try cfg.daemon_tokens.put(
            try allocator.dupe(u8, p.workspace_id),
            try allocator.dupe(u8, p.token),
        );
    }
    return cfg;
}

/// Serialize and write the config (0600, tmp + rename).
pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, cfg: *const ConfigFile) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tmp", .{ dir_path, base });
    defer allocator.free(tmp_path);

    // Ensure the parent directory exists (single level; HOME/.config is
    // expected to exist). std.c.mkdir is used because 0.17's Io.Dir has no
    // makePath and std.fs.makePath is gone.
    {
        const dir_s = try allocator.allocSentinel(u8, dir_path.len, 0);
        defer allocator.free(dir_s);
        @memcpy(dir_s[0..dir_path.len], dir_path);
        _ = std.c.mkdir(dir_s.ptr, 0o700);
    }

    var pairs: std.ArrayList(TokenPair) = .empty;
    defer pairs.deinit(allocator);
    var it = cfg.daemon_tokens.iterator();
    while (it.next()) |e| {
        try pairs.append(allocator, .{ .workspace_id = e.key_ptr.*, .token = e.value_ptr.* });
    }
    const disk = ConfigDisk{
        .server_url = cfg.server_url,
        .token = cfg.token,
        .daemon_tokens = pairs.items,
    };

    const json_str = try zfinal.JsonKit.prettify(allocator, disk);
    defer allocator.free(json_str);

    // 0600 for a token-bearing config (POSIX permissions enum).
    const tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .permissions = @enumFromInt(0o600) });
    defer tmp_file.close(io);
    // Direct positional write — the buffered Writer may not flush before
    // close on this std version, which produced empty config files.
    try std.Io.File.writePositionalAll(tmp_file, io, json_str, 0);

    std.Io.Dir.renameAbsolute(tmp_path, path, io) catch |err| {
        std.debug.print("warning: rename failed ({s}); config left at {s}\n", .{ @errorName(err), tmp_path });
        return err;
    };
}
