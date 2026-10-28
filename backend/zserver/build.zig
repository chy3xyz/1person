const std = @import("std");
const builtin = @import("builtin");
const package_zon = @import("build.zig.zon");

/// Keg-only libpq on macOS is not on the default linker search path.
const default_pg_lib_dir: []const u8 = "/opt/homebrew/opt/libpq/lib";

/// Fail loudly when the compiler is not the one this tree targets.
///
/// The target is the Zig 0.17.0 *release*. Dev snapshots are rejected on
/// purpose: ziglang.org prunes them once a release ships, so a snapshot
/// that works today stops downloading tomorrow — and the API drifted
/// between the last snapshot we used and the release (`net_read` now
/// carries a `ReadResult` struct instead of a byte count).
fn checkToolchain() void {
    const version = builtin.zig_version_string;
    const is_release = std.mem.indexOf(u8, version, "-dev") == null;
    if (!std.mem.startsWith(u8, version, "0.17.") or !is_release) {
        std.process.fatal(
            "zserver builds against the Zig 0.17.0 release; this compiler is {s}.\n" ++
                "Install the pinned toolchain with:\n" ++
                "  bash backend/zserver/scripts/install-zig.sh ~/.local\n",
            .{version},
        );
    }
}

/// zfinal's `driver_pg` build option adds the libpq *bindings* to the
/// `zfinal` module but does not `linkSystemLibrary("pq")` on it (only its
/// own `zf` CLI module does), so the final artifact has to link libpq.
fn linkPq(mod: *std.Build.Module, pg_lib_dir: []const u8) void {
    if (mod.resolved_target.?.result.os.tag == .macos) {
        mod.addLibraryPath(.{ .cwd_relative = pg_lib_dir });
    }
    mod.linkSystemLibrary("pq", .{});
}

pub fn build(b: *std.Build) void {
    checkToolchain();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pg_lib_dir = b.option([]const u8, "pg-lib", "Path to the libpq lib directory") orelse default_pg_lib_dir;

    // Version / commit injected at build time so `zserver version` reports
    // something real instead of a hardcoded placeholder.
    //
    // `-Dversion` carries the release string (the Makefile passes the
    // `git describe` output); a plain `zig build` falls back to the
    // package version. The 1p CLI reports it to the server when the
    // daemon registers, and the server stores it on the runtime row's
    // `metadata.cli_version` — that is the version the quick-create gate
    // checks.
    const build_options = b.addOptions();
    build_options.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Release version string") orelse package_zon.version,
    );
    build_options.addOption(
        []const u8,
        "commit",
        b.option([]const u8, "commit", "Git commit hash") orelse "unknown",
    );

    // Transport-error translation (port of upstream multica MUL-7466 #8761).
    // Lives under `src/cli/` next to its first consumer, but both binaries
    // need it: the 1p CLI's module root is `src/cli/main.zig` (so a plain
    // `@import("tls_error.zig")` works there), while zserver's root is
    // `src/main.zig` and `src/cli/` sits outside its tree. Exposing it as
    // a named module keeps a single implementation instead of duplicating
    // the classifier per binary.
    const tls_error_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/tls_error.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `driver_pg = true` is what enables `zfinal.ConnectionPool`'s real
    // PostgreSQL driver (and the `zfinal.Model` ORM on top of it).
    //
    // `enable-zent = false` turns off zfinal's peer data layer (zent), which
    // upstream enables by default. zserver only ever uses DB/Model, never
    // `zfinal.zent`, so leaving zent on would drag a second ORM into the
    // build for nothing. Setting the option explicitly — rather than
    // patching the dependency tree on disk — is what keeps the local build
    // and CI producing the same binary: CI resolves zfinal straight from the
    // upstream git URL, where no patch exists. zfinal guards its zent import
    // at comptime (`src/data/zent_layer.zig`), so with the option off the
    // zent package is never compiled.
    const zfinal_dep = b.dependency("zfinal", .{
        .target = target,
        .optimize = optimize,
        .driver_pg = true,
        .@"enable-zent" = false,
    });
    const zfinal_mod = zfinal_dep.module("zfinal");

    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_mod = zcli_dep.module("zcli");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfinal", .module = zfinal_mod },
            .{ .name = "zcli", .module = zcli_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "tls_error", .module = tls_error_mod },
        },
    });
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("sqlite3", .{});
    linkPq(exe_mod, pg_lib_dir);

    const exe = b.addExecutable(.{
        .name = "zserver",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zserver binary");
    run_step.dependOn(&run_cmd.step);

    // ── 1p CLI client (M1: config / login / daemon pair) ──
    // Client-only: uses zfinal for Io + HTTP (HttpClient), zcli for arg
    // parsing. Links libpq/sqlite3 defensively (the zfinal module can
    // reference them); unused symbols are dropped at link time.
    const cli_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfinal", .module = zfinal_mod },
            .{ .name = "zcli", .module = zcli_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    cli_exe_mod.link_libc = true;
    cli_exe_mod.linkSystemLibrary("sqlite3", .{});
    linkPq(cli_exe_mod, pg_lib_dir);

    const cli_exe = b.addExecutable(.{
        .name = "1p",
        .root_module = cli_exe_mod,
    });
    b.installArtifact(cli_exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfinal", .module = zfinal_mod },
            .{ .name = "zcli", .module = zcli_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "tls_error", .module = tls_error_mod },
        },
    });
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("sqlite3", .{});
    linkPq(test_mod, pg_lib_dir);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}