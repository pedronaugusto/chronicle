//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/journal/clone.zig",
        "src/journal/Encoding.zig",
        "src/journal/jsonl.zig",
        "src/journal/values.zig",
    } },
    .{ .name = "streams", .patterns = &.{
        "src/journal/streams.zig",
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
        "aegis",
        "airlock",
        "airlock.testing",
        "builtin",
        "chronicle_test_options",
        "reactor",
        "shakedown",
        "std",
        "strand",
        "warp",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "checksum owner", .target = "warp", .except_from = &.{ "src/journal.zig", "src/journal/Log.zig", "src/journal/streams.zig", "src/crc32c_test.zig" } },
    .{ .name = "strand owner", .target = "strand", .except_from = &.{"src/journal/jsonl.zig"} },
    .{ .name = "airlock owner", .target = "airlock", .except_from = &.{ "src/journal/Log.zig", "src/journal_test.zig", "src/testing/**" } },
};

pub const required = [_][]const u8{
    "src/journal/clone.zig",
    "src/journal/Encoding.zig",
    "src/journal/jsonl.zig",
    "src/journal/values.zig",
    "src/journal/streams.zig",
    "src/journal/envelope.zig",
    "src/journal/continuity.zig",
    "src/journal/facade.zig",
    "src/journal/Log.zig",
    "src/journal.zig",
    "src/chronicle.zig",
    "src/journal_test.zig",
    "src/streams_test.zig",
    "src/crc32c_test.zig",
    "src/testing/lock_helper.zig",
    "src/tests.zig",
};

/// Tokens only their owners may spell: the JSON codec is strand's, and only
/// the tests may spell `std.json`'s. Durability is preflight's door and file
/// identity the `disallowed` entries of ci/preflight.json, each by what a
/// reference resolves to.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "json owner", .tokens = &.{ "Stringify", "parseFromSlice", "parseFromSliceLeaky" }, .owners = &.{"src/*_test.zig"} },
};
