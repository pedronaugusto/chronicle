const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, no dependencies, nothing to configure: the
    // package's only knobs are the `Options` a caller passes to `open`, so
    // there is no build option to forward and no way for a consumer's build
    // graph to disagree with this one.
    //=====================================================================

    const module = b.addModule("zjournal", .{
        .root_source_file = b.path("src/zjournal.zig"),
        .target = target,
        .optimize = optimize,
    });

    //=====================================================================
    // Tests.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "zjournal-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zjournal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // A second process is the only honest way to prove that a second writer
    // is refused, so the suite spawns one. The binary is built and installed
    // here and its path handed over in the environment; a test binary run
    // without it skips that one test rather than failing.
    const lock_helper = b.addExecutable(.{
        .name = "zjournal-lock-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lock_helper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zjournal", .module = module }},
        }),
    });
    const install_lock_helper = b.addInstallArtifact(lock_helper, .{});

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&install_lock_helper.step);
    run_tests.setEnvironmentVariable(
        "ZJOURNAL_LOCK_HELPER",
        b.getInstallPath(.bin, lock_helper.out_filename),
    );

    const test_step = b.step("test", "Run zjournal tests");
    test_step.dependOn(&run_tests.step);

    // Compiling without running: the step a cross-compilation check uses, and
    // the one an editor can keep warm. It covers the tests too, which the
    // default install step does not.
    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&tests.step);
    check_step.dependOn(&lock_helper.step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the package still works. examples/usage.zig is also where
    // README.md's Usage block comes from -- see ci/readme_usage.sh -- so a
    // snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zjournal", .module = module }},
            }),
        });
        b.installArtifact(example);
        check_step.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(b.path("zig-out"));
        examples_step.dependOn(&run.step);
    }
    test_step.dependOn(examples_step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
