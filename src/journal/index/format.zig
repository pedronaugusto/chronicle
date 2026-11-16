//! A field index of one sealed segment, in a file of its own beside it,
//! `<base>.<name>.cdx`: for each record that has a key, where the record is.
//! The file is a cache, written when the segment seals and rebuilt from the
//! segment whenever it does not describe it, so everything read from it is
//! checked first, and a file that fails a check is no index.
//!
//! Two kinds:
//!
//! - exact: keys compared for equality (bytes, or integers as their eight
//!   little-endian bytes), each stored whole, at most `max_key_bytes`. The
//!   summary is a split-block Bloom filter over the keys (`filter.zig`); then
//!   the keys' table, sorted by key, each with where its bytes lie in the
//!   key heap after it, where its postings start and how many; the heap; then
//!   the postings, each a record's seq and offset and, where the index keeps
//!   one, an extra `u64` (the stream index's version). So an index lists its
//!   keys, and a lookup is exact.
//! - ordered: keys with an order (integers, instants, ids), each mapped to a
//!   `u64` that keeps it (`orderedKey`). The summary is the lowest and the
//!   highest key; then the postings, each a key, seq and offset, sorted by key
//!   and then seq, which a range bisects.
//!
//! The layout, little endian throughout: the header, the index's name, the
//! summary, the keys' table and heap (exact), the postings, and a CRC-32C of
//! everything before it. The table and the postings have fixed widths, so a
//! lookup bisects in place.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Crc32c = @import("warp").Crc32c;
const values = @import("../values.zig");
const filter = @import("filter.zig");

const Seq = values.Seq;
const Bytes = values.Bytes;
const Unparsed = values.Unparsed;

pub const extension = ".cdx";

/// How an index compares its keys.
pub const Kind = enum(u8) { exact = 1, ordered = 2 };

/// The longest index name: lower-case letters, digits and `_`, the first a
/// letter, so it can stand in a file's name as it is.
pub const max_name_bytes = 32;

/// Whether `name` can name an index.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.ascii.isLower(name[0])) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// The longest key an exact index holds: a stream id's longest.
pub const max_key_bytes = 255;

/// An ordered key as its `u64`, keeping its order: an unsigned integer as
/// it is, a signed one with its sign bit flipped.
pub fn orderedKey(value: anytype) u64 {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.bits > 64) @compileError("an ordered key is at most 64 bits");
    if (info.signedness == .unsigned) return value;
    const wide: i64 = value;
    return @as(u64, @bitCast(wide)) ^ (@as(u64, 1) << 63);
}

/// A record with a key, as a builder gives it.
pub const Entry = struct {
    /// An exact index's key, borrowed: at most `max_key_bytes`.
    bytes: []const u8 = "",
    /// An ordered index's key.
    word: u64 = 0,
    seq: Seq,
    /// Where the record's line starts in the segment.
    offset: Bytes,
    extra: u64 = 0,

    pub fn exact(key: []const u8, seq: Seq, offset: Bytes, extra: u64) Entry {
        return .{ .bytes = key, .seq = seq, .offset = offset, .extra = extra };
    }

    pub fn ordered(key: u64, seq: Seq, offset: Bytes) Entry {
        return .{ .word = key, .seq = seq, .offset = offset };
    }

    fn keyOrder(a: Entry, b: Entry) std.math.Order {
        return switch (std.mem.order(u8, a.bytes, b.bytes)) {
            .eq => std.math.order(a.word, b.word),
            else => |o| o,
        };
    }
};

/// A record found through an index.
pub const Posting = struct { seq: Seq, offset: Bytes, extra: u64 };

/// What an index file must describe: its segment, by its first record and
/// the length of its file the index was made from, and the index, by its
/// name, version and kind, and whether it keeps an extra column.
pub const Of = struct {
    base_seq: Seq,
    segment_bytes: Bytes,
    name: []const u8,
    version: u32,
    kind: Kind,
    extra: bool = false,
};

const magic = "chroncdx".*;
const format: u32 = 1;

const Header = extern struct {
    magic: [8]u8,
    format: u32,
    kind: u8,
    extra: u8,
    name_len: u8,
    pad: u8 = 0,
    version: u32,
    keys: u32,
    postings: u32,
    summary_bytes: u32,
    heap_bytes: u32,
    base_seq: u64,
    segment_bytes: u64,
};

const header_bytes = @sizeOf(Header);
/// A key in an exact index's table: where its bytes start in the heap, its
/// length, where its postings start and how many.
const key_bytes = 4 + 1 + 4 + 4;
const ordered_summary_bytes = 16;

fn postingBytes(kind: Kind, extra: bool) usize {
    return switch (kind) {
        .exact => if (extra) 24 else 16,
        .ordered => 24,
    };
}

/// The index file of `entries` (any order) into `out`, for segment and index
/// `of`. Every entry's offset lies inside the segment and its seq at or after
/// the segment's first; an ordered index's entries' `key.len` is 0.
pub fn encode(gpa: Allocator, of: Of, entries: []const Entry, out: *std.ArrayList(u8)) Allocator.Error!void {
    aegis.assert.invariant(validName(of.name), "an index's name is lower-case letters, digits and `_`, a letter first, at most 32 bytes");
    const order = try gpa.dupe(Entry, entries);
    defer gpa.free(order);
    std.sort.pdq(Entry, order, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return switch (a.keyOrder(b)) {
                .lt => true,
                .gt => false,
                .eq => a.seq.compare(b.seq) == .lt,
            };
        }
    }.lessThan);
    var keys: usize = 0;
    for (order, 0..) |e, i| {
        if (i == 0 or order[i - 1].keyOrder(e) != .eq) keys += 1;
    }
    var heap_bytes: usize = 0;
    if (of.kind == .exact) for (order, 0..) |e, i| {
        aegis.assert.invariant(e.bytes.len <= max_key_bytes, "a key is at most max_key_bytes, refused before it is appended");
        if (i == 0 or order[i - 1].keyOrder(e) != .eq) heap_bytes += e.bytes.len;
    };
    const summary_bytes = switch (of.kind) {
        .exact => filter.blocksFor(keys) * filter.block_bytes,
        .ordered => ordered_summary_bytes,
    };
    out.clearRetainingCapacity();
    const header: Header = .{
        .magic = magic,
        .format = format,
        .kind = @backingInt(of.kind),
        .extra = @intFromBool(of.extra),
        .name_len = @intCast(of.name.len),
        .version = of.version,
        .keys = if (of.kind == .exact) @intCast(keys) else 0,
        .postings = @intCast(order.len),
        .summary_bytes = @intCast(summary_bytes),
        .heap_bytes = @intCast(heap_bytes),
        .base_seq = of.base_seq.raw(),
        .segment_bytes = of.segment_bytes.raw(),
    };
    try out.appendSlice(gpa, std.mem.asBytes(&header));
    try out.appendSlice(gpa, of.name);
    const summary_at = out.items.len;
    try out.appendNTimes(gpa, 0, summary_bytes);
    switch (of.kind) {
        .exact => {
            var first: u32 = 0;
            var heap_at: u32 = 0;
            var i: usize = 0;
            while (i < order.len) {
                var end = i + 1;
                while (end < order.len and order[end].keyOrder(order[i]) == .eq) end += 1;
                try appendInt(gpa, out, u32, heap_at);
                try out.append(gpa, @intCast(order[i].bytes.len));
                try appendInt(gpa, out, u32, first);
                try appendInt(gpa, out, u32, @intCast(end - i));
                filter.add(out.items[summary_at..][0..summary_bytes], filter.hash(order[i].bytes));
                first += @intCast(end - i);
                heap_at += @intCast(order[i].bytes.len);
                i = end;
            }
            i = 0;
            while (i < order.len) : (i += 1) {
                if (i == 0 or order[i - 1].keyOrder(order[i]) != .eq) try out.appendSlice(gpa, order[i].bytes);
            }
            for (order) |e| {
                try appendInt(gpa, out, u64, e.seq.raw());
                try appendInt(gpa, out, u64, e.offset.raw());
                if (of.extra) try appendInt(gpa, out, u64, e.extra);
            }
        },
        .ordered => {
            if (order.len != 0) {
                std.mem.writeInt(u64, out.items[summary_at..][0..8], order[0].word, .little);
                std.mem.writeInt(u64, out.items[summary_at + 8 ..][0..8], order[order.len - 1].word, .little);
            }
            for (order) |e| {
                try appendInt(gpa, out, u64, e.word);
                try appendInt(gpa, out, u64, e.seq.raw());
                try appendInt(gpa, out, u64, e.offset.raw());
            }
        },
    }
    try appendInt(gpa, out, u32, Crc32c.hash(out.items));
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

/// An index file read whole and checked against what it must describe.
pub const Index = struct {
    /// The file, owned by whoever read it.
    file: []const u8,
    kind: Kind,
    extra: bool,
    keys: u32,
    postings: u32,
    summary: []const u8,
    /// The exact index's keys' table and their bytes; empty for an ordered one.
    table: []const u8,
    heap: []const u8,
    /// The postings, each `postingBytes` wide.
    entries: []const u8,

    pub const Refused = error{NotIndex};

    /// The index in `text` (an index file read whole) when it is one of
    /// `of`, whole and unaltered: its checksum holds, its header names the
    /// segment and the index, its parts fill the file exactly, and what they
    /// hold is what `encode` writes: keys in strict order, each with at least
    /// one posting and the postings taken in turn; each key's postings in
    /// strict order of seq, every seq at or after the segment's first and
    /// every offset inside it; an ordered index's postings in strict order of
    /// key and seq between its summary's lowest and highest; every key of an
    /// exact index in its filter. Borrows `text`.
    pub fn parse(text: Unparsed, of: Of) Refused!Index {
        return text.parse(of, parseFile);
    }

    fn parseFile(of: Of, file: []const u8) Refused!Index {
        if (file.len < header_bytes + 4) return error.NotIndex;
        const body = file[0 .. file.len - 4];
        if (Crc32c.hash(body) != std.mem.readInt(u32, file[file.len - 4 ..][0..4], .little)) return error.NotIndex;
        var header: Header = undefined;
        @memcpy(std.mem.asBytes(&header), body[0..header_bytes]);
        if (!std.mem.eql(u8, &header.magic, &magic) or header.format != format) return error.NotIndex;
        if (header.kind != @backingInt(of.kind) or header.extra != @intFromBool(of.extra) or header.version != of.version) return error.NotIndex;
        if (!of.base_seq.eql(.fromRaw(header.base_seq)) or !of.segment_bytes.eql(.fromRaw(header.segment_bytes))) return error.NotIndex;
        if (of.kind == .ordered and (of.extra or header.keys != 0 or header.heap_bytes != 0)) return error.NotIndex;
        const width = postingBytes(of.kind, of.extra);
        // Each part's end, every sum and product checked: the counts are the file's to say.
        const name_end = header_bytes + @as(usize, header.name_len);
        const summary_end = std.math.add(usize, name_end, header.summary_bytes) catch return error.NotIndex;
        const table_end = std.math.add(usize, summary_end, std.math.mul(usize, header.keys, key_bytes) catch return error.NotIndex) catch return error.NotIndex;
        const heap_end = std.math.add(usize, table_end, header.heap_bytes) catch return error.NotIndex;
        const entries_end = std.math.add(usize, heap_end, std.math.mul(usize, header.postings, width) catch return error.NotIndex) catch return error.NotIndex;
        if (entries_end != body.len) return error.NotIndex;
        if (!std.mem.eql(u8, body[header_bytes..name_end], of.name)) return error.NotIndex;
        const index: Index = .{
            .file = file,
            .kind = of.kind,
            .extra = of.extra,
            .keys = header.keys,
            .postings = header.postings,
            .summary = body[name_end..summary_end],
            .table = body[summary_end..table_end],
            .heap = body[table_end..heap_end],
            .entries = body[heap_end..entries_end],
        };
        switch (of.kind) {
            .exact => try index.checkExact(of),
            .ordered => try index.checkOrdered(of),
        }
        return index;
    }

    fn checkPosting(p: Posting, of: Of) Refused!void {
        if (p.seq.compare(of.base_seq) == .lt or p.offset.compare(of.segment_bytes) != .lt) return error.NotIndex;
    }

    fn checkExact(index: Index, of: Of) Refused!void {
        if (index.summary.len == 0 or index.summary.len % filter.block_bytes != 0) return error.NotIndex;
        var taken: u64 = 0;
        var heap_at: u64 = 0;
        var previous: ?[]const u8 = null;
        for (0..index.keys) |k| {
            const key = index.tableAt(k);
            // The heap is the keys' bytes in order, each after the one before: it is all used.
            if (key.at != heap_at or key.len > index.heap.len - heap_at) return error.NotIndex;
            heap_at += key.len;
            const bytes = index.heap[key.at..][0..key.len];
            if (previous) |p| if (std.mem.order(u8, p, bytes) != .lt) return error.NotIndex;
            previous = bytes;
            if (key.count == 0 or key.first != taken or key.count > index.postings - taken) return error.NotIndex;
            if (!filter.mayHold(index.summary, filter.hash(bytes))) return error.NotIndex;
            var seq: ?Seq = null;
            for (key.first..key.first + key.count) |i| {
                const p = index.at(i);
                try checkPosting(p, of);
                if (seq) |s| if (s.compare(p.seq) != .lt) return error.NotIndex;
                seq = p.seq;
            }
            taken += key.count;
        }
        if (taken != index.postings or heap_at != index.heap.len) return error.NotIndex;
    }

    fn checkOrdered(index: Index, of: Of) Refused!void {
        if (index.summary.len != ordered_summary_bytes) return error.NotIndex;
        if (index.postings == 0) return;
        const lowest = std.mem.readInt(u64, index.summary[0..8], .little);
        const highest = std.mem.readInt(u64, index.summary[8..16], .little);
        if (index.keyOf(0) != lowest or index.keyOf(index.postings - 1) != highest) return error.NotIndex;
        for (0..index.postings) |i| {
            const p = index.at(i);
            try checkPosting(p, of);
            if (i == 0) continue;
            const before = index.keyOf(i - 1);
            const key = index.keyOf(i);
            if (before > key or (before == key and index.at(i - 1).seq.compare(p.seq) != .lt)) return error.NotIndex;
        }
    }

    /// The `i`th entry of an exact index's keys' table.
    fn tableAt(index: Index, i: usize) struct { at: u64, len: u64, first: u64, count: u64 } {
        const r = index.table[i * key_bytes ..][0..key_bytes];
        return .{
            .at = std.mem.readInt(u32, r[0..4], .little),
            .len = r[4],
            .first = std.mem.readInt(u32, r[5..9], .little),
            .count = std.mem.readInt(u32, r[9..13], .little),
        };
    }

    /// The `i`th key of an exact index, which `parse` placed inside the heap.
    pub fn keyAt(index: Index, i: usize) []const u8 {
        const t = index.tableAt(i);
        return index.heap[t.at..][0..t.len];
    }

    /// The postings of an exact index's `i`th key.
    pub fn postingsOf(index: Index, i: usize) Run {
        const t = index.tableAt(i);
        return .{ .first = t.first, .end = t.first + t.count };
    }

    /// The key of an ordered index's `i`th posting.
    fn keyOf(index: Index, i: usize) u64 {
        return std.mem.readInt(u64, index.entries[i * 24 ..][0..8], .little);
    }

    /// The `i`th posting.
    pub fn at(index: Index, i: usize) Posting {
        const width = postingBytes(index.kind, index.extra);
        const r = index.entries[i * width ..][0..width];
        const fields = if (index.kind == .ordered) r[8..] else r;
        return .{
            .seq = .fromRaw(std.mem.readInt(u64, fields[0..8], .little)),
            .offset = .fromRaw(std.mem.readInt(u64, fields[8..16], .little)),
            .extra = if (index.extra) std.mem.readInt(u64, fields[16..24], .little) else 0,
        };
    }

    /// A run of postings, oldest first.
    pub const Run = struct { first: usize, end: usize };

    /// Whether the exact index's filter says `key` may be in the segment:
    /// false is certain.
    pub fn mayHold(index: Index, key: []const u8) bool {
        return filter.mayHold(index.summary, filter.hash(key));
    }

    /// The postings of `key` in an exact index, oldest first; empty when the
    /// segment holds none.
    pub fn find(index: Index, key: []const u8) Run {
        if (index.kind != .exact or !index.mayHold(key)) return .{ .first = 0, .end = 0 };
        var low: usize = 0;
        var high: usize = index.keys;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, index.keyAt(mid), key)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return index.postingsOf(mid),
            }
        }
        return .{ .first = 0, .end = 0 };
    }

    /// Whether an ordered index's keys may meet `[lo, hi]`: its lowest and
    /// highest say so.
    pub fn overlaps(index: Index, lo: u64, hi: u64) bool {
        if (index.kind != .ordered or index.postings == 0) return false;
        const lowest = std.mem.readInt(u64, index.summary[0..8], .little);
        const highest = std.mem.readInt(u64, index.summary[8..16], .little);
        return lo <= highest and lowest <= hi;
    }

    /// The postings of an ordered index whose keys lie in `[lo, hi]`, by key
    /// and then seq.
    pub fn range(index: Index, lo: u64, hi: u64) Run {
        if (!index.overlaps(lo, hi) or lo > hi) return .{ .first = 0, .end = 0 };
        return .{ .first = index.firstAtLeast(lo), .end = if (hi == std.math.maxInt(u64)) index.postings else index.firstAtLeast(hi + 1) };
    }

    fn firstAtLeast(index: Index, key: u64) usize {
        var low: usize = 0;
        var high: usize = index.postings;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (index.keyOf(mid) < key) low = mid + 1 else high = mid;
        }
        return low;
    }
};
