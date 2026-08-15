const std = @import("std");
const package_zon = @import("build.zig.zon");

/// Keg-only libpq on macOS is not on the default linker search path.
const default_pg_lib_dir: []const u8 = "/opt/homebrew/opt/libpq/lib";

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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pg_lib_dir = b.option([]const u8, "pg-lib", "Path to the libpq lib directory") orelse default_pg_lib_dir;

    // Version / commit injected at build time so `zserver version` reports
    // something real instead of a hardcoded placeholder.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package_zon.version);
    build_options.addOption(
        []const u8,
        "commit",
        b.option([]const u8, "commit", "Git commit hash") orelse "unknown",
    );

    // `driver_pg = true` is what enables `zfinal.ConnectionPool`'s real
    // PostgreSQL driver (and the `zfinal.Model` ORM on top of it).
    const zfinal_dep = b.dependency("zfinal", .{
        .target = target,
        .optimize = optimize,
        .driver_pg = true,
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