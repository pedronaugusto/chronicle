//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/Journal/clone.zig",
        "src/Journal/crc32c.zig",
        "src/Journal/encoding.zig",
        "src/Journal/jsonl.zig",
    } },
    .{ .name = "envelopes", .patterns = &.{
        "src/Journal/envelope.zig",
    } },
    .{ .name = "segments", .patterns = &.{
        "src/Journal/log.zig",
    } },
    .{ .name = "journal", .patterns = &.{
        "src/journal.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/chronicle.zig",
    } },
    .{ .name = "fixtures", .patterns = &.{
        "src/journal_test.zig",
        "src/testing/**",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/tests.zig",
    } },
};

pub const entries: []const []const u8 = &.{
    "src/testing/lock_helper.zig",
};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "chronicle", .path = "src/chronicle.zig", .from = "src/testing/lock_helper.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "std",
        "strand",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "strand owner", .target = "strand", .except_from = &.{"src/Journal/jsonl.zig"} },
};

pub const required = [_][]const u8{
    "src/Journal/clone.zig",
    "src/Journal/crc32c.zig",
    "src/Journal/encoding.zig",
    "src/Journal/jsonl.zig",
    "src/Journal/envelope.zig",
    "src/Journal/log.zig",
    "src/journal.zig",
    "src/chronicle.zig",
    "src/journal_test.zig",
    "src/testing/lock_helper.zig",
    "src/tests.zig",
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
