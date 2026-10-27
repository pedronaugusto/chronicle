//! Test assembly stays above the public journal owner.
const std = @import("std");
const chronicle = @import("chronicle.zig");

test {
    std.testing.refAllDecls(chronicle);
    _ = @import("journal_test.zig");
    _ = @import("streams_test.zig");
    _ = @import("crc32c_test.zig");
    _ = @import("crash_test.zig");
    _ = @import("explore_test.zig");
    _ = @import("journal/envelope.zig");
    _ = @import("journal/streams.zig");
    _ = @import("envelope_test.zig");
    _ = @import("testing/runtime_test.zig");
}
