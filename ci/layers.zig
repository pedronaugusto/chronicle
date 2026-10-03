//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/clone.zig",
        "src/crc32c.zig",
        "src/encoding.zig",
        "src/jsonl.zig",
    } },
    .{ .name = "envelopes", .patterns = &.{
        "src/envelope.zig",
    } },
    .{ .name = "segments", .patterns = &.{
        "src/log.zig",
    } },
    .{ .name = "journal", .patterns = &.{
        "src/journal.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/chronicle.zig",
    } },
    .{ .name = "fixtures", .patterns = &.{
        "src/journal_test.zig",
        "src/lock_helper.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/tests.zig",
    } },
};

pub const entries: []const []const u8 = &.{
    "src/lock_helper.zig",
};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "chronicle", .path = "src/chronicle.zig", .from = "src/lock_helper.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "std",
        "strand",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "strand owner", .target = "strand", .except_from = &.{"src/jsonl.zig"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};

/// Tokens only their owners may spell: durability, file identity and the
/// JSON codec are strand's; tests may check against `std.json`.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "sync owner", .token = "fsync" },
    .{ .name = "sync owner", .token = "fdatasync" },
    .{ .name = "sync owner", .token = "F_FULLFSYNC" },
    .{ .name = "sync owner", .token = "FlushFileBuffers" },
    .{ .name = "file identity owner", .token = "statx" },
    .{ .name = "file identity owner", .token = "fstat" },
    .{ .name = "json owner", .token = "Stringify", .owners = &.{"src/*_test.zig"} },
    .{ .name = "json owner", .token = "parseFromSlice", .owners = &.{"src/*_test.zig"} },
    .{ .name = "json owner", .token = "parseFromSliceLeaky", .owners = &.{"src/*_test.zig"} },
};
