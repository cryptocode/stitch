const std = @import("std");

/// Build the stitch tool, and a library that can be used to read/write resources
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stitch_mod = b.addModule("stitch", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "stitch",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Uncommenting this will use the C allocator instead of heap_allocator as the backing allocator
    // lib.linkLibC();

    const exe = b.addExecutable(.{
        .name = "stitch",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("stitch", stitch_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing.
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("stitch", stitch_mod);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
