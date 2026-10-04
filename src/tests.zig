//! Test assembly stays above the public journal owner.
const chronicle = @import("chronicle.zig");

test {
    @import("std").testing.refAllDecls(chronicle);
    _ = @import("journal_test.zig");
    _ = @import("journal/envelope.zig");
    _ = @import("journal/crc32c.zig");
}
