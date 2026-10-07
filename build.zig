const std = @import("std");

pub fn build(b: *std.Build) void {
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

    // A second process is the only honest way to prove that a second writer
    // is refused, so the suite spawns one. The helper is built here and its
    // path compiled into the suite.
    const lock_helper = b.addExecutable(.{
        .name = "chronicle-lock-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/lock_helper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chronicle", .module = module }},
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("lock_helper", lock_helper.getEmittedBin());

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const tests = b.addTest(.{
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .name = "chronicle-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (thread_sanitizer) true else null,
            .imports = &.{
                .{ .name = "strand", .module = strand },
                .{ .name = "chronicle_test_options", .module = test_options.createModule() },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

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
    // README.md's Usage block comes from -- see zig build docs -- usage -- so a
    // snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
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

    //=====================================================================
    // CI wiring
    //
    // Only in chronicle's own tree. preflight is a lazy dependency, and a
    // lazy package's build.zig can only be reached through `lazyImport`: a
    // plain `@import` of it fails to compile in any project that depends on
    // chronicle and has not fetched preflight, which is every such project.
    //=====================================================================

    if (b.pkg_hash.len != 0) return;

    //=====================================================================
    // Benchmarks
    //
    // Only in chronicle's own tree, and never part of `zig build test`: a
    // number that varies with the machine is not a thing to fail a build
    // over. `check` compiles them so they keep up with the API; `bench`
    // installs them under zig-out/bench, and each says at its top how it is
    // run. Numbers worth reading come from -Doptimize=fast.
    //=====================================================================

    const bench_options = b.addOptions();
    bench_options.addOption(bool, "smoke", b.option(
        bool,
        "bench-smoke",
        "Build the benchmarks to run once over tiny inputs, without reading a clock",
    ) orelse false);
    const bench_step = b.step("bench", "Build the benchmarks into zig-out/bench");
    for (bench_sources) |source| {
        const bench = b.addExecutable(.{
            .name = source.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(source.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "chronicle", .module = module },
                    .{ .name = "strand", .module = strand },
                },
            }),
        });
        bench.root_module.addOptions("bench_options", bench_options);
        bench_step.dependOn(&b.addInstallArtifact(bench, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
        check_step.dependOn(&bench.step);
    }

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step });
        // A project that depends on chronicle by path, with strand and
        // nothing else to fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{
            .package = "chronicle",
            .program = b.path("ci/consumer.zig"),
            .packages = &.{b.dependency("strand", .{})},
        });
    }
}

/// The benchmarks, each a program of its own.
const bench_sources = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "chronicle-bench", .path = "bench/chronicle_bench.zig" },
    .{ .name = "work-bench", .path = "bench/work_bench.zig" },
    .{ .name = "cover-bench", .path = "bench/cover_bench.zig" },
};

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/migrate.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
