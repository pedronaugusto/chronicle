//! Many streams in one journal: what a record's stream is, how a sealed
//! segment says which streams it holds, and which streams' newest versions
//! the journal keeps in memory.
//!
//! A record in a stream carries `"s"` (the stream's id) and `"sv"` (its
//! version in the stream, from 1) inside its checksum. A sealed segment gets
//! a stream index beside it, `<base>.sdx`: a filter over the ids of the
//! streams it holds, so a lookup skips a segment that cannot hold a stream
//! without reading more than the filter, then each stream's versions and
//! where their lines start. The index is a cache: it is written when the
//! segment is sealed and rebuilt from the segment when it is missing or
//! does not describe the segment's bytes.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const values = @import("values.zig");
const Crc32c = @import("warp").Crc32c;

const Seq = values.Seq;
const Bytes = values.Bytes;

const Position = struct {};

/// Where a record sits in its stream: the stream's first record is 1, and
/// each one after it is the next. Zero is the place before the first, what
/// a stream that has no record stands at.
pub const StreamVersion = aegis.id.Id(Position, u64);

/// The place before a stream's first record.
pub const no_version: StreamVersion = .fromRaw(0);

/// The longest stream id.
pub const max_id_bytes = 255;

/// A stream's id: 1 to 255 bytes of printable ASCII, neither `"` nor `\`.
/// Such an id has one spelling in JSON, the plain one, which is the one a
/// record is written and read in.
pub const Stream = struct {
    bytes: []const u8,

    pub const Invalid = error{InvalidStream};

    /// `bytes` as a stream id, borrowed: it lasts as long as `bytes` do.
    pub fn of(bytes: []const u8) Invalid!Stream {
        if (!valid(bytes)) return error.InvalidStream;
        return .{ .bytes = bytes };
    }

    pub fn eql(a: Stream, b: Stream) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub fn valid(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_id_bytes) return false;
    for (bytes) |b| if (b < 0x20 or b > 0x7e or b == '"' or b == '\\') return false;
    return true;
}

/// A stream id written as a JSON value (`"id"`) read back: the id when the
/// value is a string in the plain spelling of a valid id, null otherwise.
pub fn idOf(value: []const u8) ?Stream {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return Stream.of(value[1 .. value.len - 1]) catch null;
}

//=========================================================================
// The filter.
//=========================================================================

/// A bloom filter over stream ids: about ten bits a stream and seven probes,
/// about one false positive in a hundred, and never a false negative.
pub const Filter = struct {
    words: []const u64,

    pub const probes = 7;
    pub const bits_per_stream = 10;

    /// How many 64-bit words a filter over `streams` streams takes.
    pub fn wordsFor(streams: usize) usize {
        const bits = @max(64, streams *| bits_per_stream);
        return (bits + 63) / 64;
    }

    /// Set the bits of `id` in `words`.
    pub fn add(words: []u64, id: []const u8) void {
        var it = Probes.init(id, words.len * 64);
        for (0..probes) |_| {
            const bit = it.next();
            words[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
        }
    }

    /// Whether `id` may be among the streams: false is certain.
    pub fn mayHold(filter: Filter, id: []const u8) bool {
        if (filter.words.len == 0) return false;
        var it = Probes.init(id, filter.words.len * 64);
        for (0..probes) |_| {
            const bit = it.next();
            if (filter.words[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) == 0) return false;
        }
        return true;
    }

    /// Double hashing over two independent 64-bit hashes of the id.
    const Probes = struct {
        h1: u64,
        h2: u64,
        bits: u64,
        i: u64 = 0,

        fn init(id: []const u8, bits: usize) Probes {
            return .{
                .h1 = std.hash.Wyhash.hash(0x6368726f6e69636c, id),
                .h2 = std.hash.Wyhash.hash(0x73747265616d7321, id) | 1,
                .bits = bits,
            };
        }

        fn next(p: *Probes) usize {
            const at = (p.h1 +% p.i *% p.h2) % p.bits;
            p.i += 1;
            return @intCast(at);
        }
    };
};

//=========================================================================
// The stream index of a sealed segment.
//=========================================================================

/// One record of a stream, where it is.
pub const Entry = struct {
    version: StreamVersion,
    seq: Seq,
    /// Where its line starts in the segment's file.
    offset: Bytes,
};

/// A record's place in a stream, as a segment holds it: its stream's id is
/// owned by whatever holds the list.
pub const Placed = struct {
    id: []const u8,
    entry: Entry,
};

pub const extension = ".sdx";

const magic = "chronsdx".*;
const format: u32 = 1;

/// The header: what the index describes, so an index of other bytes is
/// refused and rebuilt.
const Header = extern struct {
    magic: [8]u8,
    format: u32,
    streams: u32,
    words: u32,
    pad: u32 = 0,
    base_seq: u64,
    /// The length of the segment's file the index was made from.
    segment_bytes: u64,
};

const header_bytes = @sizeOf(Header);

/// The index file of a segment holding `placed` (in the order they were
/// appended), into `out`: the header, the filter, then each stream sorted by
/// id with its records in order, then a CRC-32C of everything before it.
///
/// A stream's section: the id's length (one byte), the id, how many records
/// (u32), then each record's version, seq and offset (u64 each). Little
/// endian throughout.
pub fn encode(gpa: Allocator, base_seq: Seq, segment_bytes: Bytes, placed: []const Placed, out: *std.ArrayList(u8)) Allocator.Error!void {
    // The streams, each once, sorted by id; the records of each keep their
    // order, which is the order of their versions.
    const order = try gpa.alloc(usize, placed.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.sort.pdq(usize, order, placed, struct {
        fn lessThan(p: []const Placed, a: usize, b: usize) bool {
            return switch (std.mem.order(u8, p[a].id, p[b].id)) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    }.lessThan);
    var streams: usize = 0;
    for (order, 0..) |o, i| {
        if (i == 0 or !std.mem.eql(u8, placed[order[i - 1]].id, placed[o].id)) streams += 1;
    }
    const words = Filter.wordsFor(streams);

    out.clearRetainingCapacity();
    const header: Header = .{
        .magic = magic,
        .format = format,
        .streams = @intCast(streams),
        .words = @intCast(words),
        .base_seq = base_seq.raw(),
        .segment_bytes = segment_bytes.raw(),
    };
    try out.appendSlice(gpa, std.mem.asBytes(&header));
    const filter_at = out.items.len;
    try out.appendNTimes(gpa, 0, words * 8);

    var i: usize = 0;
    while (i < order.len) {
        const id = placed[order[i]].id;
        var end = i + 1;
        while (end < order.len and std.mem.eql(u8, placed[order[end]].id, id)) end += 1;
        try out.append(gpa, @intCast(id.len));
        try out.appendSlice(gpa, id);
        try appendInt(gpa, out, u32, @intCast(end - i));
        for (order[i..end]) |o| {
            const e = placed[o].entry;
            try appendInt(gpa, out, u64, e.version.raw());
            try appendInt(gpa, out, u64, e.seq.raw());
            try appendInt(gpa, out, u64, e.offset.raw());
        }
        i = end;
    }
    // The filter, set from the ids now that the buffer has stopped moving.
    {
        const bits = try gpa.alloc(u64, words);
        defer gpa.free(bits);
        @memset(bits, 0);
        var j: usize = 0;
        while (j < order.len) : (j += 1) {
            if (j == 0 or !std.mem.eql(u8, placed[order[j - 1]].id, placed[order[j]].id)) Filter.add(bits, placed[order[j]].id);
        }
        for (bits, 0..) |w, k| std.mem.writeInt(u64, out.items[filter_at + k * 8 ..][0..8], w, .little);
    }
    try appendInt(gpa, out, u32, Crc32c.hash(out.items));
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

/// A stream index read whole, checked against what it must describe.
pub const Index = struct {
    bytes: []const u8,
    streams: u32,
    /// Where the streams' sections start.
    sections: usize,

    pub const Refused = error{NotStreamIndex};

    /// `bytes` (an index file read whole, borrowed) when it is an index of
    /// segment `base_seq` at `segment_bytes` long, whole and unaltered.
    pub fn parse(bytes: []const u8, base_seq: Seq, segment_bytes: Bytes) Refused!Index {
        if (bytes.len < header_bytes + 4) return error.NotStreamIndex;
        const body = bytes[0 .. bytes.len - 4];
        if (Crc32c.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little)) return error.NotStreamIndex;
        var header: Header = undefined;
        @memcpy(std.mem.asBytes(&header), body[0..header_bytes]);
        if (!std.mem.eql(u8, &header.magic, &magic) or header.format != format) return error.NotStreamIndex;
        if (header.base_seq != base_seq.raw() or header.segment_bytes != segment_bytes.raw()) return error.NotStreamIndex;
        const filter_end = std.math.add(usize, header_bytes, std.math.mul(usize, header.words, 8) catch return error.NotStreamIndex) catch return error.NotStreamIndex;
        if (filter_end > body.len) return error.NotStreamIndex;
        const index: Index = .{
            .bytes = body,
            .streams = header.streams,
            .sections = filter_end,
        };
        // Every section has to lie inside the body, so a walk never reads
        // past it.
        var it = index.iterator();
        var n: u32 = 0;
        while (it.next() catch return error.NotStreamIndex) |_| n += 1;
        if (n != header.streams or it.at != body.len) return error.NotStreamIndex;
        return index;
    }

    /// Whether the index's filter says `id` may be in the segment.
    pub fn mayHold(index: Index, id: []const u8) bool {
        const words_at = header_bytes;
        const words = (index.sections - words_at) / 8;
        if (words == 0) return false;
        var it = Filter.Probes.init(id, words * 64);
        for (0..Filter.probes) |_| {
            const bit = it.next();
            const word = std.mem.readInt(u64, index.bytes[words_at + (bit / 64) * 8 ..][0..8], .little);
            if (word & (@as(u64, 1) << @intCast(bit % 64)) == 0) return false;
        }
        return true;
    }

    /// The records of stream `id` in the segment, oldest first, or null when
    /// it holds none.
    pub fn find(index: Index, id: []const u8) ?Section {
        if (!index.mayHold(id)) return null;
        var it = index.iterator();
        while (it.next() catch return null) |section| {
            switch (std.mem.order(u8, section.id, id)) {
                .lt => continue,
                .eq => return section,
                .gt => return null,
            }
        }
        return null;
    }

    pub fn iterator(index: Index) Iterator {
        return .{ .bytes = index.bytes, .at = index.sections };
    }

    pub const Iterator = struct {
        bytes: []const u8,
        at: usize,

        pub fn next(it: *Iterator) Refused!?Section {
            if (it.at == it.bytes.len) return null;
            const rest = it.bytes[it.at..];
            if (rest.len < 1) return error.NotStreamIndex;
            const len = rest[0];
            if (rest.len < 1 + len + 4) return error.NotStreamIndex;
            const id = rest[1 .. 1 + len];
            const count = std.mem.readInt(u32, rest[1 + len ..][0..4], .little);
            const records_at = 1 + len + 4;
            const records_len = std.math.mul(usize, count, 24) catch return error.NotStreamIndex;
            if (rest.len - records_at < records_len or count == 0 or !valid(id)) return error.NotStreamIndex;
            it.at += records_at + records_len;
            return .{ .id = id, .records = rest[records_at..][0..records_len] };
        }
    };

    /// One stream's records in a segment.
    pub const Section = struct {
        id: []const u8,
        records: []const u8,

        pub fn len(section: Section) usize {
            return section.records.len / 24;
        }

        pub fn at(section: Section, i: usize) Entry {
            const r = section.records[i * 24 ..][0..24];
            return .{
                .version = .fromRaw(std.mem.readInt(u64, r[0..8], .little)),
                .seq = .fromRaw(std.mem.readInt(u64, r[8..16], .little)),
                .offset = .fromRaw(std.mem.readInt(u64, r[16..24], .little)),
            };
        }

        pub fn last(section: Section) Entry {
            return section.at(section.len() - 1);
        }
    };
};

//=========================================================================
// The streams' heads.
//=========================================================================

/// What the journal knows of a stream's newest record.
pub const Head = struct {
    /// Its version, or `no_version` when the stream has none.
    version: StreamVersion,
};

/// The heads of the streams touched most recently, at most `capacity` of
/// them: a lookup that misses goes to the segments, and what it finds comes
/// here, pushing out the stream touched longest ago. Its memory grows with
/// the streams it holds, up to `capacity` of them; a head it cannot find
/// room for is not kept, which costs the next lookup of it a read.
pub const Heads = struct {
    gpa: Allocator,
    capacity: u32,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    /// Most recent first; `none` ends a list.
    first: u32 = none,
    last: u32 = none,
    free: u32 = none,
    used: u32 = 0,

    const none = std.math.maxInt(u32);

    const Node = struct {
        id: [max_id_bytes]u8 = undefined,
        len: u8 = 0,
        head: Head = .{ .version = no_version },
        prev: u32 = none,
        next: u32 = none,

        fn key(node: *const Node) []const u8 {
            return node.id[0..node.len];
        }
    };

    pub fn init(gpa: Allocator, capacity: u32) Heads {
        return .{ .gpa = gpa, .capacity = capacity };
    }

    pub fn deinit(heads: *Heads) void {
        heads.map.deinit(heads.gpa);
        heads.nodes.deinit(heads.gpa);
        heads.* = undefined;
    }

    /// Forget every head: the segments are what they say again.
    pub fn clear(heads: *Heads) void {
        heads.map.clearRetainingCapacity();
        heads.first = none;
        heads.last = none;
        heads.free = none;
        heads.used = 0;
    }

    pub fn get(heads: *Heads, id: []const u8) ?Head {
        const i = heads.map.get(id) orelse return null;
        heads.touch(i);
        return heads.nodes.items[i].head;
    }

    /// Keep `head` for `id`, as the most recent, when there is room.
    pub fn put(heads: *Heads, id: []const u8, head: Head) void {
        if (heads.capacity == 0) return;
        if (heads.map.get(id)) |i| {
            heads.nodes.items[i].head = head;
            heads.touch(i);
            return;
        }
        const i: u32 = if (heads.used < heads.capacity) blk: {
            if (heads.used == heads.nodes.items.len) {
                heads.nodes.append(heads.gpa, .{}) catch return;
            }
            heads.map.ensureUnusedCapacity(heads.gpa, 1) catch return;
            heads.used += 1;
            break :blk heads.used - 1;
        } else blk: {
            // The stream touched longest ago gives up its place.
            const oldest = heads.last;
            heads.unlink(oldest);
            _ = heads.map.remove(heads.nodes.items[oldest].key());
            break :blk oldest;
        };
        const node = &heads.nodes.items[i];
        node.* = .{ .len = @intCast(id.len), .head = head };
        @memcpy(node.id[0..id.len], id);
        heads.map.putAssumeCapacity(node.key(), i);
        heads.pushFront(i);
    }

    fn touch(heads: *Heads, i: u32) void {
        if (heads.first == i) return;
        heads.unlink(i);
        heads.pushFront(i);
    }

    fn unlink(heads: *Heads, i: u32) void {
        const node = &heads.nodes.items[i];
        if (node.prev != none) heads.nodes.items[node.prev].next = node.next else heads.first = node.next;
        if (node.next != none) heads.nodes.items[node.next].prev = node.prev else heads.last = node.prev;
        node.prev = none;
        node.next = none;
    }

    fn pushFront(heads: *Heads, i: u32) void {
        const node = &heads.nodes.items[i];
        node.prev = none;
        node.next = heads.first;
        if (heads.first != none) heads.nodes.items[heads.first].prev = i;
        heads.first = i;
        if (heads.last == none) heads.last = i;
    }
};

//=========================================================================
// What the journal holds of its streams.
//=========================================================================

/// The records of the active segment that are in streams, each stream's
/// newest version there, the heads of streams found in sealed segments, and
/// each stream's truncation point.
pub const Book = struct {
    gpa: Allocator,
    /// The segment `placed` describes.
    active_base: Seq = .fromRaw(0),
    /// The active segment's records in streams, in the order appended. Each
    /// id is one of `ids`.
    placed: std.ArrayList(Placed) = .empty,
    /// The ids of the active segment's streams, each once.
    ids: std.heap.ArenaAllocator,
    /// Each stream's newest version in the active segment.
    last: std.StringHashMapUnmanaged(StreamVersion) = .empty,
    /// Streams' newest versions in sealed segments, as far as they have been
    /// looked up; `no_version` for one no segment holds.
    heads: Heads,
    /// The version below which each truncated stream's records are not
    /// read. Owns its keys.
    truncations: std.StringHashMapUnmanaged(StreamVersion) = .empty,
    /// Where a stream index is built before it is written.
    buf: std.ArrayList(u8) = .empty,
    /// Whether `placed` and `last` may not describe the active segment: a
    /// record whose place could not be noted, a batch taken back. The next
    /// lookup reads the active segment again first.
    stale: bool = true,

    pub fn init(gpa: Allocator, heads: u32) Book {
        return .{ .gpa = gpa, .ids = .init(gpa), .heads = .init(gpa, heads) };
    }

    pub fn deinit(book: *Book) void {
        book.placed.deinit(book.gpa);
        book.last.deinit(book.gpa);
        book.ids.deinit();
        book.heads.deinit();
        book.clearTruncations();
        book.truncations.deinit(book.gpa);
        book.buf.deinit(book.gpa);
        book.* = undefined;
    }

    /// Describe an empty active segment named `base`.
    pub fn resetActive(book: *Book, base: Seq) void {
        book.stale = false;
        book.active_base = base;
        book.placed.clearRetainingCapacity();
        book.last.clearRetainingCapacity();
        _ = book.ids.reset(.retain_capacity);
    }

    /// A record of stream `id` in the active segment.
    pub fn place(book: *Book, id: []const u8, entry: Entry) Allocator.Error!void {
        try book.placed.ensureUnusedCapacity(book.gpa, 1);
        const slot = try book.last.getOrPut(book.gpa, id);
        if (!slot.found_existing) {
            slot.key_ptr.* = book.ids.allocator().dupe(u8, id) catch |err| {
                book.last.removeByPtr(slot.key_ptr);
                return err;
            };
        }
        slot.value_ptr.* = entry.version;
        book.placed.appendAssumeCapacity(.{ .id = slot.key_ptr.*, .entry = entry });
    }

    /// Forget the records placed after the first `len`: a batch that was
    /// staged and taken back.
    pub fn rollback(book: *Book, len: usize) void {
        if (len >= book.placed.items.len) return;
        book.placed.shrinkRetainingCapacity(len);
        book.last.clearRetainingCapacity();
        for (book.placed.items) |p| book.last.putAssumeCapacity(p.id, p.entry.version);
    }

    /// The newest version of stream `id` in the active segment.
    pub fn activeVersion(book: *const Book, id: []const u8) ?StreamVersion {
        return book.last.get(id);
    }

    /// The version below which stream `id` is not read: `no_version` when
    /// it has never been truncated.
    pub fn truncation(book: *const Book, id: []const u8) StreamVersion {
        return book.truncations.get(id) orelse no_version;
    }

    pub fn setTruncation(book: *Book, id: []const u8, before: StreamVersion) Allocator.Error!void {
        const slot = try book.truncations.getOrPut(book.gpa, id);
        if (!slot.found_existing) {
            slot.key_ptr.* = book.gpa.dupe(u8, id) catch |err| {
                book.truncations.removeByPtr(slot.key_ptr);
                return err;
            };
        }
        slot.value_ptr.* = before;
    }

    pub fn clearTruncations(book: *Book) void {
        var it = book.truncations.keyIterator();
        while (it.next()) |key| book.gpa.free(key.*);
        book.truncations.clearRetainingCapacity();
    }
};

//=========================================================================
// Tests.
//=========================================================================

const testing = std.testing;

test "a stream id is printable ASCII with neither quote nor backslash, 1 to 255 bytes" {
    try testing.expect(valid("order-7"));
    try testing.expect(valid("a b/c:d"));
    try testing.expect(!valid(""));
    try testing.expect(!valid("a\"b"));
    try testing.expect(!valid("a\\b"));
    try testing.expect(!valid("tab\there"));
    try testing.expect(!valid("caf\xc3\xa9"));
    const longest: [255]u8 = @splat('x');
    const too_long: [256]u8 = @splat('x');
    try testing.expect(valid(&longest));
    try testing.expect(!valid(&too_long));
    try testing.expectEqualStrings("order-7", idOf("\"order-7\"").?.bytes);
    try testing.expect(idOf("\"a\\u0062\"") == null);
    try testing.expect(idOf("7") == null);
}

test "a filter never forgets a stream it holds, and refuses most it does not" {
    const ids = 2000;
    var words: [Filter.wordsFor(ids)]u64 = @splat(0);
    var name: [16]u8 = undefined;
    for (0..ids) |i| Filter.add(&words, std.fmt.bufPrint(&name, "in-{d}", .{i}) catch unreachable);
    const filter: Filter = .{ .words = &words };
    for (0..ids) |i| try testing.expect(filter.mayHold(std.fmt.bufPrint(&name, "in-{d}", .{i}) catch unreachable));
    var wrong: usize = 0;
    for (0..ids) |i| {
        if (filter.mayHold(std.fmt.bufPrint(&name, "out-{d}", .{i}) catch unreachable)) wrong += 1;
    }
    // About 1%; 3% is far outside what ten bits a stream gives.
    try testing.expect(wrong < ids * 3 / 100);
}

test "a stream index finds each stream's records and refuses one of other bytes" {
    const gpa = testing.allocator;
    const placed = [_]Placed{
        .{ .id = "b", .entry = .{ .version = .fromRaw(1), .seq = .fromRaw(10), .offset = .fromRaw(40) } },
        .{ .id = "a", .entry = .{ .version = .fromRaw(4), .seq = .fromRaw(11), .offset = .fromRaw(90) } },
        .{ .id = "b", .entry = .{ .version = .fromRaw(2), .seq = .fromRaw(12), .offset = .fromRaw(140) } },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encode(gpa, .fromRaw(10), .fromRaw(200), &placed, &out);
    const index = try Index.parse(out.items, .fromRaw(10), .fromRaw(200));
    try testing.expectEqual(@as(u32, 2), index.streams);
    const b = index.find("b").?;
    try testing.expectEqual(@as(usize, 2), b.len());
    try testing.expectEqual(StreamVersion.fromRaw(2), b.last().version);
    try testing.expectEqual(Bytes.fromRaw(40), b.at(0).offset);
    try testing.expectEqual(Seq.fromRaw(11), index.find("a").?.at(0).seq);
    try testing.expect(index.find("c") == null);
    try testing.expectError(error.NotStreamIndex, Index.parse(out.items, .fromRaw(10), .fromRaw(201)));
    out.items[out.items.len - 10] ^= 1;
    try testing.expectError(error.NotStreamIndex, Index.parse(out.items, .fromRaw(10), .fromRaw(200)));
}

test "the heads keep the streams touched most recently, up to their capacity" {
    var heads = Heads.init(testing.allocator, 2);
    defer heads.deinit();
    heads.put("a", .{ .version = .fromRaw(1) });
    heads.put("b", .{ .version = .fromRaw(2) });
    _ = heads.get("a");
    heads.put("c", .{ .version = .fromRaw(3) });
    try testing.expect(heads.get("b") == null);
    try testing.expectEqual(StreamVersion.fromRaw(1), heads.get("a").?.version);
    try testing.expectEqual(StreamVersion.fromRaw(3), heads.get("c").?.version);
    heads.put("a", .{ .version = .fromRaw(5) });
    try testing.expectEqual(StreamVersion.fromRaw(5), heads.get("a").?.version);
    heads.clear();
    try testing.expect(heads.get("a") == null);
}
