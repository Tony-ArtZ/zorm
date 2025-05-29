const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the zorm library (static)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zorm",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);
    _ = b.addModule("zorm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the generator executable
    const generator_exe = b.addExecutable(.{
        .name = "zorm-generator",
        .root_source_file = b.path("src/generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    generator_exe.root_module.addImport("zorm", lib_mod);
    b.installArtifact(generator_exe);

    // Add a separate build step for the generator
    const generator_step = b.step("generator", "Build only the zorm-generator executable");
    generator_step.dependOn(&generator_exe.step);

    // Build the example executable
    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = b.path("examples/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_exe.linkLibC();
    example_exe.linkSystemLibrary("pq");
    example_exe.linkSystemLibrary("sqlite3");
    example_exe.root_module.addImport("zorm", lib_mod);
    b.installArtifact(example_exe);
}
