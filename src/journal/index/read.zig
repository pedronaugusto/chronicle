//! Reading field indexes: what a read by key asks (`Asked`), the postings of
//! a sealed segment's index file that answer it, and the summaries of sealed
//! segments' indexes kept in memory (`Summaries`), so that a segment that
//! cannot hold what is asked is passed over without its file being opened.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const values = @import("../values.zig");
const format = @import("format.zig");
const filter = @import("filter.zig");

const Seq = values.Seq;
const Bytes = values.Bytes;

/// What a read by key asks for: the records with one exact key, or with an
/// ordered key in a range, both ends in.
pub const Asked = union(enum) {
    exact: Key,
    ordered: Range,
    /// What no record can have: an exact key past `format.max_key_bytes`
    /// (refused at append), or a range whose low end is above its high.
    none,

    pub const Key = struct {
        buffer: [format.max_key_bytes]u8,
        len: usize,
        hash: u64,
    };
    pub const Range = struct { lo: u64, hi: u64 };

    pub fn exactKey(bytes: []const u8) Asked {
        if (bytes.len > format.max_key_bytes) return .none;
        var key: Key = .{ .buffer = undefined, .len = bytes.len, .hash = filter.hash(bytes) };
        @memcpy(key.buffer[0..bytes.len], bytes);
        return .{ .exact = key };
    }

    pub fn between(lo: u64, hi: u64) Asked {
        if (lo > hi) return .none;
        return .{ .ordered = .{ .lo = lo, .hi = hi } };
    }

    /// The exact key asked for.
    pub fn keyBytes(asked: *const Asked) []const u8 {
        return asked.exact.buffer[0..asked.exact.len];
    }

    /// Whether a record whose exact key is `bytes` is asked for.
    pub fn holdsBytes(asked: *const Asked, bytes: []const u8) bool {
        return asked.* == .exact and std.mem.eql(u8, asked.keyBytes(), bytes);
    }

    /// Whether a record whose ordered key is `word` is asked for.
    pub fn holdsWord(asked: *const Asked, word: u64) bool {
        return switch (asked.*) {
            .ordered => |r| r.lo <= word and word <= r.hi,
            else => false,
        };
    }

    /// Whether a segment whose index is summarized by `summary` may hold a
    /// record asked for: false is certain.
    pub fn admits(asked: *const Asked, summary: Summary) bool {
        return switch (asked.*) {
            .none => false,
            .exact => |k| switch (summary) {
                .filter => |f| filter.mayHold(f, k.hash),
                .span, .empty => false,
            },
            .ordered => |r| switch (summary) {
                .span => |s| r.lo <= s.hi and s.lo <= r.hi,
                .filter, .empty => false,
            },
        };
    }

    /// The postings of `index` that answer it, with a seq past `after`,
    /// oldest first, into `out`.
    pub fn postingsIn(asked: *const Asked, gpa: Allocator, index: format.Index, after: Seq, out: *std.ArrayList(format.Posting)) Allocator.Error!void {
        out.clearRetainingCapacity();
        const run: format.Index.Run = switch (asked.*) {
            .none => .{ .first = 0, .end = 0 },
            .exact => index.find(asked.keyBytes()),
            .ordered => |r| index.range(r.lo, r.hi),
        };
        for (run.first..run.end) |i| {
            const p = index.at(i);
            if (p.seq.compare(after) == .gt) try out.append(gpa, p);
        }
        // An ordered index's run is by key, then seq: a read is by seq.
        if (asked.* == .ordered) std.sort.pdq(format.Posting, out.items, {}, bySeq);
    }
};

fn bySeq(_: void, a: format.Posting, b: format.Posting) bool {
    return a.seq.compare(b.seq) == .lt;
}

/// A sealed segment's index, summarized: an exact index's filter, or an
/// ordered index's lowest and highest key.
pub const Summary = union(enum) {
    filter: []const u8,
    span: Asked.Range,
    /// An ordered index with no posting.
    empty,

    pub fn of(index: format.Index) Summary {
        return switch (index.kind) {
            .exact => .{ .filter = index.summary },
            .ordered => if (index.postings == 0) .empty else .{ .span = .{
                .lo = std.mem.readInt(u64, index.summary[0..8], .little),
                .hi = std.mem.readInt(u64, index.summary[8..16], .little),
            } },
        };
    }

    fn bytes(summary: Summary) usize {
        return switch (summary) {
            .filter => |f| f.len,
            .span, .empty => 0,
        };
    }
};

/// The summaries of sealed segments' indexes, read for lookups by key and
/// kept under a limit, the least recently used dropped past it and read
/// again from their files when asked for. A segment is known by its first
/// record and its length, so a segment rewritten to another length is
/// another; whatever rewrites one in place clears them.
pub const Summaries = struct {
    /// Which segment's index: its first record, its length, and the index's
    /// place in the declarations.
    pub const Of = struct { base_seq: u64, segment_bytes: u64, index: u32 };

    pub const Found = union(enum) {
        summary: Summary,
        /// Its file did not describe its segment: the segment is read whole
        /// until the index is built again.
        stale,
    };

    const Held = struct { found: Found, used: u64 };

    /// What one summary is charged besides its filter: its slot.
    const slot_bytes = @sizeOf(Of) + @sizeOf(Held) + 16;

    held: std.AutoHashMapUnmanaged(Of, Held) = .empty,
    limit: Bytes,
    charged: usize = 0,
    clock: u64 = 0,

    pub fn init(limit: Bytes) Summaries {
        return .{ .limit = limit };
    }

    pub fn deinit(s: *Summaries, gpa: Allocator) void {
        s.clear(gpa);
        s.held.deinit(gpa);
        s.* = undefined;
    }

    /// What is held for `of`, if anything, marked as just used.
    pub fn get(s: *Summaries, of: Of) ?Found {
        const held = s.held.getPtr(of) orelse return null;
        s.clock += 1;
        held.used = s.clock;
        return held.found;
    }

    /// `index`'s summary kept for `of`, its filter copied. One that would not
    /// fit under the limit with every other dropped is not kept.
    pub fn put(s: *Summaries, gpa: Allocator, of: Of, index: format.Index) Allocator.Error!void {
        const summary: Summary = .of(index);
        const cost = slot_bytes + summary.bytes();
        if (cost > values.limit(s.limit)) return;
        s.drop(gpa, of);
        s.makeRoom(gpa, cost);
        const owned: Summary = switch (summary) {
            .filter => |f| .{ .filter = try gpa.dupe(u8, f) },
            else => summary,
        };
        errdefer if (owned == .filter) gpa.free(owned.filter);
        s.clock += 1;
        try s.held.put(gpa, of, .{ .found = .{ .summary = owned }, .used = s.clock });
        s.charged += cost;
    }

    /// `of`'s index found not to describe its segment.
    pub fn markStale(s: *Summaries, gpa: Allocator, of: Of) Allocator.Error!void {
        s.drop(gpa, of);
        if (slot_bytes > values.limit(s.limit)) return;
        s.makeRoom(gpa, slot_bytes);
        s.clock += 1;
        try s.held.put(gpa, of, .{ .found = .stale, .used = s.clock });
        s.charged += slot_bytes;
    }

    /// Whatever is held for `of` dropped.
    pub fn drop(s: *Summaries, gpa: Allocator, of: Of) void {
        const removed = s.held.fetchRemove(of) orelse return;
        s.release(gpa, removed.value);
    }

    /// Every summary dropped: the segments were read again or rewritten.
    pub fn clear(s: *Summaries, gpa: Allocator) void {
        var it = s.held.valueIterator();
        while (it.next()) |held| s.release(gpa, held.*);
        s.held.clearRetainingCapacity();
        s.charged = 0;
    }

    pub fn count(s: *const Summaries) usize {
        return s.held.count();
    }

    fn release(s: *Summaries, gpa: Allocator, held: Held) void {
        switch (held.found) {
            .summary => |summary| {
                s.charged -= slot_bytes + summary.bytes();
                if (summary == .filter) gpa.free(summary.filter);
            },
            .stale => s.charged -= slot_bytes,
        }
    }

    /// The least recently used dropped until `cost` more fits.
    fn makeRoom(s: *Summaries, gpa: Allocator, cost: usize) void {
        const limit = values.limit(s.limit);
        while (s.charged + cost > limit) {
            var oldest: ?Of = null;
            var used: u64 = std.math.maxInt(u64);
            var it = s.held.iterator();
            while (it.next()) |e| if (e.value_ptr.used < used) {
                used = e.value_ptr.used;
                oldest = e.key_ptr.*;
            };
            s.drop(gpa, oldest orelse return);
        }
    }
};

const testing = std.testing;

fn encoded(entries: []const format.Entry, kind: format.Kind) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try format.encode(testing.allocator, .{ .base_seq = .fromRaw(1), .segment_bytes = .fromRaw(4096), .name = "k", .version = 1, .kind = kind }, entries, &out);
    return out.toOwnedSlice(testing.allocator);
}

test "a read asks for its key's postings past where it stands, by seq, and a summary says which segments may hold them" {
    const gpa = testing.allocator;
    const exact = try encoded(&.{ .exact("a", .fromRaw(1), .fromRaw(10), 0), .exact("b", .fromRaw(2), .fromRaw(20), 0), .exact("a", .fromRaw(3), .fromRaw(30), 0) }, .exact);
    defer gpa.free(exact);
    const index = try format.Index.parse(.init(exact), .{ .base_seq = .fromRaw(1), .segment_bytes = .fromRaw(4096), .name = "k", .version = 1, .kind = .exact });
    var out: std.ArrayList(format.Posting) = .empty;
    defer out.deinit(gpa);
    const a: Asked = .exactKey("a");
    try testing.expect(a.admits(.of(index)));
    try a.postingsIn(gpa, index, .fromRaw(1), &out);
    try testing.expectEqual(1, out.items.len);
    try testing.expect(out.items[0].seq.eql(.fromRaw(3)));
    const none: Asked = .exactKey(&@as([format.max_key_bytes + 1]u8, @splat('x')));
    try testing.expect(none == .none and !none.admits(.of(index)));

    const ordered = try encoded(&.{ .ordered(9, .fromRaw(1), .fromRaw(10)), .ordered(2, .fromRaw(2), .fromRaw(20)), .ordered(5, .fromRaw(3), .fromRaw(30)) }, .ordered);
    defer gpa.free(ordered);
    const oindex = try format.Index.parse(.init(ordered), .{ .base_seq = .fromRaw(1), .segment_bytes = .fromRaw(4096), .name = "k", .version = 1, .kind = .ordered });
    const r: Asked = .between(2, 9);
    try r.postingsIn(gpa, oindex, values.beginning, &out);
    try testing.expectEqual(3, out.items.len);
    for (out.items, 1..) |p, seq| try testing.expect(p.seq.eql(.fromRaw(seq)));
    try testing.expect(!Asked.between(10, 20).admits(.of(oindex)));
    try testing.expect(Asked.between(9, 9).admits(.of(oindex)));
    try testing.expect(Asked.between(3, 2) == .none);
}

test "summaries are kept under their limit, the least recently used dropped first" {
    const gpa = testing.allocator;
    const file = try encoded(&.{.exact("a", .fromRaw(1), .fromRaw(10), 0)}, .exact);
    defer gpa.free(file);
    const index = try format.Index.parse(.init(file), .{ .base_seq = .fromRaw(1), .segment_bytes = .fromRaw(4096), .name = "k", .version = 1, .kind = .exact });
    const one = Summaries.slot_bytes + index.summary.len;
    var s: Summaries = .init(.fromRaw(2 * one));
    defer s.deinit(gpa);
    try s.put(gpa, .{ .base_seq = 1, .segment_bytes = 1, .index = 0 }, index);
    try s.put(gpa, .{ .base_seq = 2, .segment_bytes = 1, .index = 0 }, index);
    _ = s.get(.{ .base_seq = 1, .segment_bytes = 1, .index = 0 });
    try s.put(gpa, .{ .base_seq = 3, .segment_bytes = 1, .index = 0 }, index);
    try testing.expectEqual(2, s.count());
    try testing.expect(s.get(.{ .base_seq = 2, .segment_bytes = 1, .index = 0 }) == null);
    try testing.expect(s.get(.{ .base_seq = 1, .segment_bytes = 1, .index = 0 }) != null);
    try s.markStale(gpa, .{ .base_seq = 3, .segment_bytes = 1, .index = 0 });
    try testing.expect(s.get(.{ .base_seq = 3, .segment_bytes = 1, .index = 0 }).? == .stale);
    var tiny: Summaries = .init(.fromRaw(1));
    defer tiny.deinit(gpa);
    try tiny.put(gpa, .{ .base_seq = 1, .segment_bytes = 1, .index = 0 }, index);
    try testing.expectEqual(0, tiny.count());
}
