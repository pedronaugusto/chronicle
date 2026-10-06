//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/journal/clone.zig",
        "src/journal/crc32c.zig",
        "src/journal/Encoding.zig",
        "src/journal/jsonl.zig",
    } },
    .{ .name = "envelopes", .patterns = &.{
        "src/journal/envelope.zig",
        "src/journal/continuity.zig",
        "src/journal/facade.zig",
    } },
    .{ .name = "segments", .patterns = &.{
        "src/journal/Log.zig",
    } },
    .{ .name = "journal", .patterns = &.{
        "src/journal.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/chronicle.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "chronicle", .path = "src/chronicle.zig", .from = "src/testing/lock_helper.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "std",
        "strand",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "strand owner", .target = "strand", .except_from = &.{"src/journal/jsonl.zig"} },
};

pub const required = [_][]const u8{
    "src/journal/clone.zig",
    "src/journal/crc32c.zig",
    "src/journal/Encoding.zig",
    "src/journal/jsonl.zig",
    "src/journal/envelope.zig",
    "src/journal/continuity.zig",
    "src/journal/facade.zig",
    "src/journal/Log.zig",
    "src/journal.zig",
    "src/chronicle.zig",
    "src/journal_test.zig",
    "src/testing/lock_helper.zig",
    "src/tests.zig",
};

/// Tokens only their owners may spell: durability, file identity and the
/// JSON codec are strand's; tests may check against `std.json`.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "sync owner", .tokens = &.{ "fsync", "fdatasync", "F_FULLFSYNC", "FlushFileBuffers" } },
    .{ .name = "file identity owner", .tokens = &.{ "statx", "fstat" } },
    .{ .name = "json owner", .tokens = &.{ "Stringify", "parseFromSlice", "parseFromSliceLeaky" }, .owners = &.{"src/*_test.zig"} },
};
