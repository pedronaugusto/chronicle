const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    const optimize = b.standardOptimizeOption(.{});
    const chronicle_dep = b.dependency("chronicle", .{ .target = target, .optimize = optimize });
    const chronicle = chronicle_dep.module("chronicle");
    const strand = chronicle.import_table.get("strand").?;

    const chronicle_bench = b.addExecutable(.{
        .name = "chronicle-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chronicle_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chronicle", .module = chronicle },
                .{ .name = "strand", .module = strand },
            },
        }),
    });
    chronicle_bench.root_module.addOptions("bench_options", options);
    b.installArtifact(chronicle_bench);

    const file_bench = b.addExecutable(.{
        .name = "plain-zig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plain_zig_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    file_bench.root_module.addOptions("bench_options", options);
    b.installArtifact(file_bench);
}
