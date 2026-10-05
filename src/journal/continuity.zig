//! Sequence, checksum and atomic-batch continuity across segment boundaries.
const std = @import("std");
const envelope = @import("envelope.zig");

pub fn State(comptime Header: type, comptime ReadError: type, comptime Boundary: type) type {
    return struct {
        const Self = @This();
        pub const Error = ReadError;
        pub const SegmentBoundary = Boundary;
        pub const RecordHeader = Header;
        cursor: u64,
        expected: ?u64 = null,
        link: ?u32 = null,
        /// The atomic batch the walk is inside, from its first record to
        /// its last.
        batch: ?envelope.Batch = null,
        /// Whether a record has been walked yet: the first one may be
        /// inside a batch whose start the walk began after, or that a
        /// compaction cut.
        walked: bool = false,

        pub fn beginSegment(walk: *Self, boundary: SegmentBoundary) Error!void {
            // A batch is never split across segments.
            if (walk.batch != null) return error.BrokenBatch;
            if (walk.expected) |want| {
                if (boundary.base_seq != want) return error.DiscontinuousSeq;
            }
            if (walk.link) |previous| {
                if (boundary.root != previous) return error.BrokenChain;
            }
            walk.expected = boundary.base_seq;
            walk.link = boundary.root;
        }

        /// Whether this record is one to hand on. False means it is at or
        /// behind the cursor and has been stepped over.
        pub fn accept(walk: *Self, header: RecordHeader) Error!bool {
            std.debug.assert(header.seq > 0);
            std.debug.assert(header.seq <= std.math.maxInt(i64));
            if (header.batch) |batch| {
                std.debug.assert(batch.first <= header.seq);
                std.debug.assert(header.seq <= batch.last);
            }
            if (walk.expected) |want| {
                if (header.seq != want) return error.DiscontinuousSeq;
            }
            if (walk.link) |previous| {
                if (header.p != previous) return error.BrokenChain;
            }
            try walk.acceptBatch(header);
            walk.expected = header.seq + 1;
            walk.link = header.c;
            return header.seq > walk.cursor;
        }

        /// A batch's records come one after another, each naming the
        /// batch, from its first to its last, and nothing else does.
        fn acceptBatch(walk: *Self, header: RecordHeader) Error!void {
            defer walk.walked = true;
            if (walk.batch) |inside| {
                const named = header.batch orelse return error.BrokenBatch;
                if (named.first != inside.first or named.last != inside.last) return error.BrokenBatch;
                if (header.seq == inside.last) walk.batch = null;
                return;
            }
            const named = header.batch orelse return;
            if (header.seq != named.first and walk.walked) return error.BrokenBatch;
            if (header.seq != named.last) walk.batch = named;
        }
    };
}
