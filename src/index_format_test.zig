//! The field index file (`journal/index/format.zig`): what `encode` writes
//! reads back as the entries it was given, by key and by range; a file that
//! is damaged anywhere, or describes another segment or index, is refused;
//! and any bytes at all are refused or read within their bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const format = @import("journal/index.zig").format;

const testing = std.testing;
const gen = shakedown.gen;
const Entry = format.Entry;
const Index = format.Index;

const segment_bytes = 1 << 20;

fn ofKind(kind: format.Kind, extra: bool) format.Of {
    return .{ .base_seq = .fromRaw(100), .segment_bytes = .fromRaw(segment_bytes), .name = "account", .version = 3, .kind = kind, .extra = extra };
}

fn encoded(entries: []const Entry, of: format.Of) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try format.encode(testing.allocator, of, entries, &out);
    return out.toOwnedSlice(testing.allocator);
}

/// Keys from a small alphabet, 0 to 12 bytes long, so some repeat, some are
/// stored whole and some by their hash.
fn drawKey(s: *shakedown.Source, buffer: []u8) []const u8 {
    const len = gen.intRange(s, usize, 0, 12);
    for (buffer[0..len]) |*b| b.* = "abc"[gen.intRange(s, usize, 0, 2)];
    return buffer[0..len];
}

const Drawn = struct { key: [12]u8, len: usize };

fn exactOne(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    const extra = gen.boolean(s);
    const n = gen.intRange(s, usize, 0, 40);
    var keys: [40]Drawn = undefined;
    var entries: [40]Entry = undefined;
    for (0..n) |i| {
        const key = drawKey(s, &keys[i].key);
        keys[i].len = key.len;
        // Seqs rise with the index, offsets anywhere in the segment.
        entries[i] = .exact(key, .fromRaw(100 + i), .fromRaw(gen.intRange(s, u64, 0, segment_bytes - 1)), gen.int(s, u64));
    }
    // The entries in any order: encode sorts them.
    const shuffled = try gpa.dupe(Entry, entries[0..n]);
    defer gpa.free(shuffled);
    for (0..n) |i| std.mem.swap(Entry, &shuffled[i], &shuffled[gen.intRange(s, usize, i, n -| 1)]);
    const of = ofKind(.exact, extra);
    const file = try encoded(shuffled, of);
    defer gpa.free(file);
    const index = try Index.parse(.init(file), of);
    try testing.expectEqual(@as(u32, @intCast(n)), index.postings);
    // Each key drawn, and a stranger, read back as the entries with that key, oldest first.
    var probe: [12]u8 = undefined;
    const stranger = drawKey(s, &probe);
    for (0..n + 1) |k| {
        const key = if (k == n) stranger else keys[k].key[0..keys[k].len];
        const run = index.find(key);
        var at = run.first;
        for (entries[0..n]) |e| {
            if (e.key.order(format.Stored.of(key)) != .eq) continue;
            try testing.expect(at < run.end);
            const p = index.at(at);
            try testing.expect(p.seq.eql(e.seq) and p.offset.eql(e.offset));
            try testing.expectEqual(if (extra) e.extra else 0, p.extra);
            at += 1;
        }
        try testing.expectEqual(run.end, at);
    }
}

fn orderedOne(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    const n = gen.intRange(s, usize, 0, 40);
    var entries: [40]Entry = undefined;
    for (0..n) |i| {
        const key = format.orderedKey(gen.intRange(s, i64, -5, 5));
        entries[i] = .ordered(key, .fromRaw(100 + i), .fromRaw(gen.intRange(s, u64, 0, segment_bytes - 1)));
    }
    const of = ofKind(.ordered, false);
    const file = try encoded(entries[0..n], of);
    defer gpa.free(file);
    const index = try Index.parse(.init(file), of);
    const lo = format.orderedKey(gen.intRange(s, i64, -7, 7));
    const hi = format.orderedKey(gen.intRange(s, i64, -7, 7));
    const run = index.range(lo, hi);
    // The range holds exactly the entries with a key in it, by key and then seq.
    var expected: [40]Entry = undefined;
    var m: usize = 0;
    for (entries[0..n]) |e| if (lo <= e.key.word and e.key.word <= hi) {
        expected[m] = e;
        m += 1;
    };
    std.sort.pdq(Entry, expected[0..m], {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.key.word < b.key.word or (a.key.word == b.key.word and a.seq.compare(b.seq) == .lt);
        }
    }.lessThan);
    try testing.expectEqual(m, run.end - run.first);
    for (expected[0..m], run.first..) |e, i| try testing.expect(index.at(i).seq.eql(e.seq));
}

test "an exact index reads back each key's records, oldest first, with their extra column" {
    try shakedown.check(testing.allocator, {}, exactOne, .{ .seed = 0x65786163, .cases = 300 });
}

test "an ordered index reads back the records of a range of keys, by key and then seq" {
    try shakedown.check(testing.allocator, {}, orderedOne, .{ .seed = 0x6f726465, .cases = 300 });
}

test "ordered keys keep their order, signed ones across zero" {
    try testing.expect(format.orderedKey(@as(i64, -1)) < format.orderedKey(@as(i64, 0)));
    try testing.expect(format.orderedKey(@as(i64, std.math.minInt(i64))) < format.orderedKey(@as(i64, -1)));
    try testing.expect(format.orderedKey(@as(i32, 7)) < format.orderedKey(@as(i64, 8)));
    try testing.expectEqual(@as(u64, 9), format.orderedKey(@as(u64, 9)));
}

test "an index of another segment or another index, or damaged anywhere, is refused" {
    const gpa = testing.allocator;
    const of = ofKind(.exact, true);
    const entries = [_]Entry{
        .exact("ab", .fromRaw(100), .fromRaw(0), 1),
        .exact("a key past eight bytes", .fromRaw(101), .fromRaw(40), 2),
        .exact("ab", .fromRaw(102), .fromRaw(80), 3),
    };
    const file = try encoded(&entries, of);
    defer gpa.free(file);
    _ = try Index.parse(.init(file), of);
    var other = of;
    other.base_seq = .fromRaw(101);
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    other = of;
    other.segment_bytes = .fromRaw(segment_bytes + 1);
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    other = of;
    other.name = "kind";
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    other = of;
    other.version = 4;
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    other = of;
    other.extra = false;
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    other = of;
    other.kind = .ordered;
    try testing.expectError(error.NotIndex, Index.parse(.init(file), other));
    // Every shorter file, and every bit flipped.
    for (0..file.len) |len| try testing.expectError(error.NotIndex, Index.parse(.init(file[0..len]), of));
    const copy = try gpa.dupe(u8, file);
    defer gpa.free(copy);
    for (0..copy.len * 8) |bit| {
        copy[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try testing.expectError(error.NotIndex, Index.parse(.init(copy), of));
        copy[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
    }
}

test "a posting outside its segment, or before its first record, is refused though its checksum holds" {
    const gpa = testing.allocator;
    const of = ofKind(.exact, false);
    const outside = try encoded(&.{.exact("a", .fromRaw(100), .fromRaw(segment_bytes), 0)}, of);
    defer gpa.free(outside);
    try testing.expectError(error.NotIndex, Index.parse(.init(outside), of));
    const before = try encoded(&.{.exact("a", .fromRaw(99), .fromRaw(0), 0)}, of);
    defer gpa.free(before);
    try testing.expectError(error.NotIndex, Index.parse(.init(before), of));
}

/// Any bytes, or a good file with its bytes changed and its checksum made
/// to hold again, are refused or read within their bounds.
fn anyOne(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    const kind: format.Kind = if (gen.boolean(s)) .exact else .ordered;
    const of = ofKind(kind, kind == .exact and gen.boolean(s));
    var buffer: [1024]u8 = undefined;
    const bytes = if (gen.boolean(s)) gen.bytesInto(s, &buffer) else good: {
        const entries = [_]Entry{
            if (kind == .exact) .exact("ab", .fromRaw(100), .fromRaw(0), 1) else .ordered(3, .fromRaw(100), .fromRaw(0)),
            if (kind == .exact) .exact("a key past eight bytes", .fromRaw(101), .fromRaw(40), 2) else .ordered(1, .fromRaw(101), .fromRaw(40)),
        };
        const file = try encoded(&entries, of);
        defer gpa.free(file);
        const len = @min(file.len, buffer.len);
        @memcpy(buffer[0..len], file[0..len]);
        for (0..gen.intRange(s, usize, 1, 4)) |_| buffer[gen.intRange(s, usize, 0, len - 5)] = gen.int(s, u8);
        // The checksum made to hold, so the checks past it are what refuse.
        std.mem.writeInt(u32, buffer[len - 4 ..][0..4], @import("warp").Crc32c.hash(buffer[0 .. len - 4]), .little);
        break :good buffer[0..len];
    };
    const index = Index.parse(.init(bytes), of) catch return;
    for (0..index.postings) |i| _ = index.at(i);
    _ = index.find("ab");
    _ = index.find("a key past eight bytes");
    _ = index.range(0, std.math.maxInt(u64));
}

test "fuzz: any bytes are refused as an index, or read within their bounds" {
    try shakedown.check(testing.allocator, {}, anyOne, .{ .seed = 0x66757a7a, .cases = 2000 });
}
