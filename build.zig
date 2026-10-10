const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, three dependencies, nothing to configure: the
    // package's only knobs are the `Options` a caller passes to `open`, so
    // there is no build option to forward and no way for a consumer's build
    // graph to disagree with this one. strand reads and writes a record's
    // line, airlock makes files durable, warp owns checksums and aegis owns
    // the kinds of number; this package keeps the lines.
    //=====================================================================

    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const warp = b.dependency("warp", .{ .target = target, .optimize = optimize }).module("warp");
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const airlock_dependency = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const module = b.addModule("chronicle", .{
        .root_source_file = b.path("src/chronicle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "warp", .module = warp },
            .{ .name = "strand", .module = strand },
            .{ .name = "airlock", .module = airlock },
        },
    });

    // Everything below is chronicle's own: a project depending on chronicle
    // neither builds nor fetches its tests, examples, benchmarks or CI.
    if (b.pkg_hash.len != 0) return;

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
                .{ .name = "aegis", .module = aegis },
                .{ .name = "warp", .module = warp },
                .{ .name = "strand", .module = strand },
                .{ .name = "airlock", .module = airlock },
                .{ .name = "chronicle_test_options", .module = test_options.createModule() },
            },
        }),
    });
    // shakedown, and airlock's seam on it, are lazy and test-only: no
    // module a consumer builds imports them. Their error is returned last,
    // so one configure pass asks for them and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    if (airlock_build.testing(airlock_dependency)) |seam| {
        tests.root_module.addImport("airlock.testing", seam);
    } else |err| needed = err;
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
                // A migration parses an older event out of its bytes with
                // strand, which a program that keeps events depends on too.
                .imports = &.{ .{ .name = "chronicle", .module = module }, .{ .name = "strand", .module = strand } },
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
    // preflight is a lazy dependency, and a lazy package's build.zig can
    // only be reached through `lazyImport`: a plain `@import` of it fails to
    // compile in any project that depends on chronicle and has not fetched
    // preflight, which is every such project.
    //=====================================================================

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        // `zig build bench` times each program in bench/ in ReleaseFast, one
        // after another, each running every workload it has; `zig build
        // test` runs each once with `--smoke`.
        preflight.addCi(b, .{
            .tests = test_step,
            .bench = .{
                .programs = &.{
                    .{ .name = "chronicle-bench", .source = "bench/chronicle_bench.zig" },
                    .{ .name = "work-bench", .source = "bench/work_bench.zig" },
                    .{ .name = "cover-bench", .source = "bench/cover_bench.zig" },
                },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on chronicle by path, with strand, airlock
        // and warp and nothing else to fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{
            .package = "chronicle",
            .program = b.path("ci/consumer.zig"),
            .packages = &.{ b.dependency("aegis", .{}), b.dependency("strand", .{}), b.dependency("airlock", .{}), b.dependency("warp", .{}) },
        });
    }
    return needed;
}

/// chronicle, aegis, strand, airlock and warp again, in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over
/// the Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const warp = b.dependency("warp", .{ .target = target, .optimize = optimize }).module("warp");
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const airlock = b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const chronicle = b.createModule(.{
        .root_source_file = b.path("src/chronicle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "warp", .module = warp },
            .{ .name = "strand", .module = strand },
            .{ .name = "airlock", .module = airlock },
        },
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "chronicle", .module = chronicle },
        .{ .name = "strand", .module = strand },
        .{ .name = "airlock", .module = airlock },
    }) catch @panic("OOM");
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/migrate.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
