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
        "airlock",
        "builtin",
        "chronicle_test_options",
        "shakedown",
        "std",
        "strand",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "strand owner", .target = "strand", .except_from = &.{"src/journal/jsonl.zig"} },
    .{ .name = "airlock owner", .target = "airlock", .except_from = &.{ "src/journal/Log.zig", "src/journal_test.zig", "src/testing/**" } },
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

/// Tokens only their owners may spell: durability and file identity are
/// airlock's, so nothing here spells them; the JSON codec is strand's, and
/// tests may check against `std.json`.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "durability belongs to airlock", .tokens = &.{
        "fsync",
        "fdatasync",
        "F_FULLFSYNC",
        "FULLFSYNC",
        "F_BARRIERFSYNC",
        "BARRIERFSYNC",
        "FlushFileBuffers",
        "NtFlushBuffersFile",
        "NtFlushBuffersFileEx",
        "createFileAtomic",
    } },
    .{ .name = "file identity belongs to airlock", .tokens = &.{ "statx", "fstat", "fstatat", "FILE_ID_INFO" } },
    .{ .name = "json owner", .tokens = &.{ "Stringify", "parseFromSlice", "parseFromSliceLeaky" }, .owners = &.{"src/*_test.zig"} },
};
