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
const log = std.log.scoped(.chronicle);
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const values = @import("values.zig");
const format = @import("index.zig").format;

const Seq = values.Seq;
const Bytes = values.Bytes;
const Unparsed = values.Unparsed;

const Version = struct {};
const Position = struct {
    /// What versions are moved by: a number of a stream's records.
    pub const Step = Versions;
};

/// Where a record sits in its stream: the stream's first record is 1, and
/// each one after it is the next. Zero is the place before the first, what
/// a stream that has no record stands at.
pub const StreamVersion = aegis.id.Id(Position, u64);

/// A number of a stream's records: what a version moves by.
pub const Versions = aegis.units.Count(Version, u64);

/// The place before a stream's first record.
pub const no_version: StreamVersion = .fromRaw(0);

/// The last version a record can have: a version is written as a JSON
/// integer, so it ends where `i64` does.
pub const last_version: StreamVersion = .fromRaw(std.math.maxInt(i64));

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

/// The stream index is the field index format's (`index/format.zig`): the
/// exact index named `stream`, whose keys are the streams' ids, kept whole,
/// and whose extra column is each record's version. Version 1 of it; a stream
/// index in the format before, one of its own, reads as no index and is
/// rebuilt.
fn indexOf(base_seq: Seq, segment_bytes: Bytes) format.Of {
    return .{ .base_seq = base_seq, .segment_bytes = segment_bytes, .name = "stream", .version = 1, .kind = .exact, .extra = true };
}

/// The index file of a segment holding `placed` (in the order they were
/// appended), into `out`.
pub fn encode(gpa: Allocator, base_seq: Seq, segment_bytes: Bytes, placed: []const Placed, out: *std.ArrayList(u8)) Allocator.Error!void {
    const entries = try gpa.alloc(format.Entry, placed.len);
    defer gpa.free(entries);
    for (entries, placed) |*e, p| e.* = .exact(p.id, p.entry.seq, p.entry.offset, p.entry.version.raw());
    return format.encode(gpa, indexOf(base_seq, segment_bytes), entries, out);
}

/// A stream index read whole, checked against what it must describe.
pub const Index = struct {
    index: format.Index,
    /// How many streams the segment holds.
    streams: u32,

    pub const Refused = error{NotStreamIndex};

    /// The segment an index must describe: its first record, and the
    /// length of its file the index was made from.
    pub const Of = struct { base_seq: Seq, bytes: Bytes };

    /// The index in `text` (an index file read whole) when it is one of
    /// segment `of`, as `format.Index.parse` checks it, and its streams'
    /// records are what a journal writes: each id a valid stream id, each
    /// stream's versions rising from 1 and at most `last_version`. Borrows
    /// `text`.
    pub fn parse(text: Unparsed, of: Of) Refused!Index {
        const index = format.Index.parse(text, indexOf(of.base_seq, of.bytes)) catch return error.NotStreamIndex;
        for (0..index.keys) |k| {
            if (!valid(index.keyAt(k))) return error.NotStreamIndex;
            const run = index.postingsOf(k);
            var version = no_version;
            for (run.first..run.end) |i| {
                const v: StreamVersion = .fromRaw(index.at(i).extra);
                if (v.compare(version) != .gt or v.compare(last_version) == .gt) return error.NotStreamIndex;
                version = v;
            }
        }
        return .{ .index = index, .streams = index.keys };
    }

    /// The file given back to `gpa`, which read it.
    pub fn deinit(index: Index, gpa: Allocator) void {
        gpa.free(index.index.file);
    }

    /// Whether the index's filter says `id` may be in the segment.
    pub fn mayHold(index: Index, id: []const u8) bool {
        return index.index.mayHold(id);
    }

    /// The records of stream `id` in the segment, oldest first, or null when
    /// it holds none.
    pub fn find(index: Index, id: []const u8) ?Section {
        const run = index.index.find(id);
        if (run.first == run.end) return null;
        return .{ .id = id, .index = index.index, .run = run };
    }

    pub fn iterator(index: Index) Iterator {
        return .{ .index = index.index };
    }

    /// The streams of an index, in order of id.
    pub const Iterator = struct {
        index: format.Index,
        at: usize = 0,

        pub fn next(it: *Iterator) ?Section {
            if (it.at == it.index.keys) return null;
            defer it.at += 1;
            return .{ .id = it.index.keyAt(it.at), .index = it.index, .run = it.index.postingsOf(it.at) };
        }
    };

    /// One stream's records in a segment.
    pub const Section = struct {
        id: []const u8,
        index: format.Index,
        run: format.Index.Run,

        pub fn len(section: Section) usize {
            return section.run.end - section.run.first;
        }

        pub fn at(section: Section, i: usize) Entry {
            const p = section.index.at(section.run.first + i);
            return .{ .version = .fromRaw(p.extra), .seq = p.seq, .offset = p.offset };
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
    /// Node indexes, hashed and compared by the ids their nodes hold:
    /// `nodes` moves when it grows, so the map keeps no pointer into it.
    map: std.HashMapUnmanaged(u32, void, Keys, std.hash_map.default_max_load_percentage) = .empty,
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

    /// The map's context: a node's index stands for the id it holds.
    pub const Keys = struct {
        nodes: []const Node,

        pub fn hash(k: Keys, i: u32) u64 {
            return std.hash_map.hashString(k.nodes[i].key());
        }

        pub fn eql(k: Keys, a: u32, b: u32) bool {
            return std.mem.eql(u8, k.nodes[a].key(), k.nodes[b].key());
        }
    };

    /// A lookup by id.
    pub const ById = struct {
        nodes: []const Node,

        pub fn hash(_: ById, id: []const u8) u64 {
            return std.hash_map.hashString(id);
        }

        pub fn eql(k: ById, id: []const u8, i: u32) bool {
            return std.mem.eql(u8, id, k.nodes[i].key());
        }
    };

    fn keys(heads: *const Heads) Keys {
        return .{ .nodes = heads.nodes.items };
    }

    fn find(heads: *const Heads, id: []const u8) ?u32 {
        return heads.map.getKeyAdapted(id, ById{ .nodes = heads.nodes.items });
    }

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
        const i = heads.find(id) orelse return null;
        heads.touch(i);
        return heads.nodes.items[i].head;
    }

    /// Keep `head` for `id`, as the most recent, when there is room.
    pub fn put(heads: *Heads, id: []const u8, head: Head) void {
        if (heads.capacity == 0) return;
        if (heads.find(id)) |i| {
            heads.nodes.items[i].head = head;
            heads.touch(i);
            return;
        }
        const i: u32 = if (heads.used < heads.capacity) blk: {
            if (heads.used == heads.nodes.items.len) {
                heads.nodes.append(heads.gpa, .{}) catch |err| return log.debug("stream head not kept ({t}): a head is kept only when there is room", .{err});
            }
            // After the append: a rehash reads the nodes where they are now.
            heads.map.ensureUnusedCapacityContext(heads.gpa, 1, heads.keys()) catch |err| return log.debug("stream head not kept ({t}): a head is kept only when there is room", .{err});
            heads.used += 1;
            break :blk heads.used - 1;
        } else blk: {
            // The stream touched longest ago gives up its place.
            const oldest = heads.last;
            heads.unlink(oldest);
            _ = heads.map.removeAdapted(heads.nodes.items[oldest].key(), ById{ .nodes = heads.nodes.items });
            break :blk oldest;
        };
        const node = &heads.nodes.items[i];
        node.* = .{ .len = @intCast(id.len), .head = head };
        @memcpy(node.id[0..id.len], id);
        heads.map.putAssumeCapacityNoClobberContext(i, {}, heads.keys());
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

    /// Stream `id`'s truncation point put back to `was`, what it was before
    /// `setTruncation` moved it: allocates nothing, so an undo cannot fail.
    pub fn restoreTruncation(book: *Book, id: []const u8, was: StreamVersion) void {
        if (was == no_version) {
            const removed = book.truncations.fetchRemove(id) orelse return;
            book.gpa.free(removed.key);
        } else if (book.truncations.getPtr(id)) |point| point.* = was;
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
    const of: Index.Of = .{ .base_seq = .fromRaw(10), .bytes = .fromRaw(200) };
    const index = try Index.parse(.init(out.items), of);
    try testing.expectEqual(@as(u32, 2), index.streams);
    const b = index.find("b").?;
    try testing.expectEqual(@as(usize, 2), b.len());
    try testing.expectEqual(StreamVersion.fromRaw(2), b.last().version);
    try testing.expectEqual(Bytes.fromRaw(40), b.at(0).offset);
    try testing.expectEqual(Seq.fromRaw(11), index.find("a").?.at(0).seq);
    try testing.expect(index.find("c") == null);
    try testing.expectError(error.NotStreamIndex, Index.parse(.init(out.items), .{ .base_seq = .fromRaw(10), .bytes = .fromRaw(201) }));
    out.items[out.items.len - 10] ^= 1;
    try testing.expectError(error.NotStreamIndex, Index.parse(.init(out.items), of));
}

test "a field index whose checksum holds is still no stream index when its ids or versions are not a journal's" {
    const gpa = testing.allocator;
    const of: Index.Of = .{ .base_seq = .fromRaw(10), .bytes = .fromRaw(200) };
    const cases = [_][2]format.Entry{
        // Versions falling within a stream.
        .{ .exact("a", .fromRaw(10), .fromRaw(0), 2), .exact("a", .fromRaw(11), .fromRaw(50), 1) },
        // A version repeated.
        .{ .exact("a", .fromRaw(10), .fromRaw(0), 1), .exact("a", .fromRaw(11), .fromRaw(50), 1) },
        // A version of zero, and one past the last a record can have.
        .{ .exact("a", .fromRaw(10), .fromRaw(0), 0), .exact("b", .fromRaw(11), .fromRaw(50), 1) },
        .{ .exact("a", .fromRaw(10), .fromRaw(0), 1), .exact("b", .fromRaw(11), .fromRaw(50), last_version.raw() + 1) },
        // An id no stream can have.
        .{ .exact("a\"b", .fromRaw(10), .fromRaw(0), 1), .exact("b", .fromRaw(11), .fromRaw(50), 1) },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (cases) |entries| {
        try format.encode(gpa, indexOf(of.base_seq, of.bytes), &entries, &out);
        try testing.expectError(error.NotStreamIndex, Index.parse(.init(out.items), of));
    }
}

test "a truncation point put back is the one it was, an absent one absent again" {
    var book = Book.init(testing.allocator, 4);
    defer book.deinit();
    try book.setTruncation("a", .fromRaw(3));
    try book.setTruncation("a", .fromRaw(7));
    book.restoreTruncation("a", .fromRaw(3));
    try testing.expectEqual(StreamVersion.fromRaw(3), book.truncation("a"));
    try book.setTruncation("b", .fromRaw(5));
    book.restoreTruncation("b", no_version);
    try testing.expectEqual(no_version, book.truncation("b"));
    try testing.expect(book.truncations.get("b") == null);
}

test "the heads find every stream they keep after their memory grew and moved" {
    var heads = Heads.init(testing.allocator, 1000);
    defer heads.deinit();
    var buf: [16]u8 = undefined;
    for (0..1000) |i| heads.put(try std.mem.print(&buf, "s-{d}", .{i}), .{ .version = .fromRaw(i + 1) });
    for (0..1000) |i| {
        const head = heads.get(try std.mem.print(&buf, "s-{d}", .{i})) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(StreamVersion.fromRaw(i + 1), head.version);
    }
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
