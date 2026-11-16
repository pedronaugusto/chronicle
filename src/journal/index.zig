//! Field indexes: a file beside each sealed segment per index, for each
//! record with a key, where the record is (`format`), summarized for
//! skipping segments by an exact index's filter (`filter`) or an ordered
//! index's lowest and highest key, kept in memory for the reads by key
//! (`read`).
//!
//! This file is internal. `chronicle.zig` is the package.

pub const filter = @import("index/filter.zig");
pub const format = @import("index/format.zig");
pub const build = @import("index/build.zig");
pub const declare = @import("index/declare.zig");
pub const read = @import("index/read.zig");

test {
    _ = filter;
    _ = read;
    _ = build;
    _ = declare;
}
