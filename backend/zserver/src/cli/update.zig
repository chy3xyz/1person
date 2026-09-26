//! 1p self-update (M5): check the latest release, download the platform
//! binary, sanity-check it, and replace the current executable.
//!
//! Release layout served from `--from <base>` (default GitHub latest):
//!   {base}/version.txt                      -> "0.2.0"
//!   {base}/1person-{arch}-{os}              -> executable (tar-free)
//!   {base}/1person-{arch}-{os}.sha256       -> hex digest (optional)
//!
//! Verification: the downloaded file must start with a Mach-O (macOS) or
//! ELF (Linux) magic and, when a .sha256 sibling exists, match it.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const out = @import("out.zig");
const build_options = @import("build_options");

pub const UpdateOptions = struct {
    from: ?[]const u8 = null,
    target: ?[]const u8 = null, // default: current executable (argv[0])
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: UpdateOptions) !void {
    const base = opts.from orelse "https://github.com/chy3xyz/1person/releases/latest/download";
    const target = opts.target orelse {
        out.printErr("no target path (argv[0] resolution unsupported here) — pass --target\n", .{});
        return error.TargetRequired;
    };

    var client = try api.Client.init(allocator, base);
    defer client.deinit();

    // 1. latest version
    const ver_raw = try client.getRaw(allocator, "/version.txt");
    defer allocator.free(ver_raw);
    const latest = std.mem.trim(u8, ver_raw, &std.ascii.whitespace);
    if (latest.len == 0) return error.InvalidVersionFile;
    out.printOut("current: {s}   latest: {s}\n", .{ build_options.version, latest });

    if (std.mem.eql(u8, latest, build_options.version)) {
        out.printOut("already up to date\n", .{});
        return;
    }

    // 2. download the platform binary
    const artifact = try artifactName(allocator);
    defer allocator.free(artifact);
    const bin_path = try std.fmt.allocPrint(allocator, "/{s}", .{artifact});
    defer allocator.free(bin_path);
    out.printOut("downloading {s}{s}\n", .{ base, bin_path });
    const blob = try client.getRaw(allocator, bin_path);
    defer allocator.free(blob);

    // 3. sanity-check the header
    if (!validExecutableMagic(blob)) {
        out.printErr("downloaded file is not a valid executable — refusing to install\n", .{});
        return error.InvalidBinary;
    }

    // 4. checksum (optional .sha256 sibling)
    const sha_path = try std.fmt.allocPrint(allocator, "/{s}.sha256", .{artifact});
    defer allocator.free(sha_path);
    const sum_raw = client.getRaw(allocator, sha_path) catch null;
    if (sum_raw) |sr| {
        defer allocator.free(sr);
        const expected = std.mem.trim(u8, sr, &std.ascii.whitespace);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
        const got = &std.fmt.bytesToHex(digest, .lower);
        if (expected.len != got.len or !std.mem.eql(u8, expected, got)) {
            out.printErr("checksum mismatch — refusing to install\n", .{});
            return error.ChecksumMismatch;
        }
        out.printOut("checksum ok\n", .{});
    }

    // 5. write to target.new + chmod + rename
    const tmp = try std.fmt.allocPrint(allocator, "{s}.new", .{target});
    defer allocator.free(tmp);
    const tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp, .{ .permissions = @enumFromInt(0o755), .truncate = true });
    defer tmp_file.close(io);
    try std.Io.File.writePositionalAll(tmp_file, io, blob, 0);

    std.Io.Dir.renameAbsolute(tmp, target, io) catch |err| {
        out.printErr("rename failed ({s}); new binary left at {s}\n", .{ @errorName(err), tmp });
        return err;
    };
    out.printOut("updated to {s} at {s}\n", .{ latest, target });
}

fn artifactName(allocator: std.mem.Allocator) ![]const u8 {
    const os_str: []const u8 = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedPlatform,
    };
    const arch_str: []const u8 = switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedPlatform,
    };
    return std.fmt.allocPrint(allocator, "1person-{s}-{s}", .{ arch_str, os_str });
}

fn validExecutableMagic(blob: []const u8) bool {
    if (blob.len < 4) return false;
    // Mach-O 64-bit: CF FA ED FE ; ELF: 7F 45 4C 46
    const macho = std.mem.eql(u8, blob[0..4], &[_]u8{ 0xCF, 0xFA, 0xED, 0xFE });
    const elf = std.mem.eql(u8, blob[0..4], &[_]u8{ 0x7F, 0x45, 0x4C, 0x46 });
    return macho or elf;
}
