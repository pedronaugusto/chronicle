const std = @import("std");

pub fn build(b: *std.Build) void {
    importChecks(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, one dependency, nothing to configure: the
    // package's only knobs are the `Options` a caller passes to `open`, so
    // there is no build option to forward and no way for a consumer's build
    // graph to disagree with this one. strand reads and writes a record's
    // line; this package keeps the lines.
    //=====================================================================

    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const module = b.addModule("chronicle", .{
        .root_source_file = b.path("src/chronicle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "strand", .module = strand }},
    });

    //=====================================================================
    // Tests.
    //=====================================================================

    // A journal is one mutex between an appender and the tasks that wait on
    // `waitPast` or fold live through a sink, and a clean reopen inspects
    // the segments concurrently. Whether those are free of races is a claim
    // a race detector can check and a reader cannot:
    // `zig build test -Dthread-sanitizer`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    // Error return traces are off on the test binary, so that the second
    // binary `zig build test --fuzz` builds goes through Zig 0.16.0's test
    // runner without them. The suite reports the same failures either way;
    // what is lost is the chain of returns behind an unexpected error.
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .name = "chronicle-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (thread_sanitizer) true else null,
            .error_tracing = false,
            .imports = &.{.{ .name = "strand", .module = strand }},
        }),
    });

    // A second process is the only honest way to prove that a second writer
    // is refused, so the suite spawns one. The binary is built and installed
    // here and its path handed over in the environment; a test binary run
    // without it skips that one test rather than failing.
    const lock_helper = b.addExecutable(.{
        .name = "chronicle-lock-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/lock_helper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chronicle", .module = module }},
        }),
    });
    const install_lock_helper = b.addInstallArtifact(lock_helper, .{});

    const run_tests = b.addRunArtifact(tests);
    // A stalled test must fail by name, including in an ordinary local run.
    // Zig 0.16 passes per-test timeouts through MakeOptions rather than a
    // Run field, so give this one test runner a default there. An explicit
    // --test-timeout still takes precedence; fuzzing keeps its own runner.
    const TestTimeout = struct {
        var run: std.Build.Step.MakeFn = undefined;

        fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
            var bounded = options;
            bounded.unit_test_timeout_ns = options.unit_test_timeout_ns orelse 120 * std.time.ns_per_s;
            return run(step, bounded);
        }
    };
    TestTimeout.run = run_tests.step.makeFn;
    run_tests.step.makeFn = TestTimeout.make;
    run_tests.step.dependOn(&install_lock_helper.step);
    run_tests.setEnvironmentVariable(
        "CHRONICLE_LOCK_HELPER",
        b.getInstallPath(.bin, lock_helper.out_filename),
    );

    const test_step = b.step("test", "Run chronicle tests");
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
                .imports = &.{.{ .name = "chronicle", .module = module }},
            }),
        });
        b.installArtifact(example);
        check_step.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(b.path("zig-out"));
        examples_step.dependOn(&run.step);
    }
    if (test_filter == null) test_step.dependOn(examples_step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/migrate.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
fn importChecks(b: *std.Build) void {
    const step = b.step("check-imports", "Check source layers and import boundaries");
    if (b.pkg_hash.len != 0) return;
    const dependency = if (b.lazyDependency("gantry", .{ .target = b.graph.host, .optimize = .Debug })) |dep| dep.module("gantry") else return;
    const checker = b.addExecutable(.{
        .name = "check-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/imports.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "gantry", .module = dependency }},
        }),
    });
    const run = b.addRunArtifact(checker);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}
