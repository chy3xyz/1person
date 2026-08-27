const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zcli", .{
        .root_source_file = b.path("src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_test = b.addTest(.{
        .root_module = mod,
    });
    const run_test = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run zcli tests");
    test_step.dependOn(&run_test.step);
}
