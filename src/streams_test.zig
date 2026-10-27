//! Many streams in one journal: versions, expectations, reads of one
//! stream, the stream indexes beside sealed segments, the heads kept in
//! memory, and truncation. Every test opens a real journal on a real
//! directory.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");

const Event = union(enum) {
    deposited: struct { amount: u32 },
    withdrew: struct { amount: u32 },
};

const Journal = chronicle.Journal(Event);
const Stream = chronicle.Stream;
const StreamVersion = chronicle.StreamVersion;
const Seq = chronicle.Seq;

fn stream(id: []const u8) Stream {
    return Stream.of(id) catch unreachable; // unreachable: the tests name valid ids
}

fn deposit(amount: u32) Event {
    return .{ .deposited = .{ .amount = amount } };
}

/// A journal's directory under a fresh temporary one.
const Place = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !Place {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        return .{ .tmp = tmp, .path = try std.Io.Dir.path.join(testing.allocator, &.{ root, "log" }) };
    }

    fn deinit(p: *Place) void {
        testing.allocator.free(p.path);
        p.tmp.cleanup();
    }
};

/// The name of segment `base`'s stream index.
fn sdxName(buf: *[64]u8, base: u64) []const u8 {
    const log_name = chronicle.segmentName(.fromRaw(base));
    const stem = log_name[0 .. log_name.len - chronicle.segment_extension.len];
    return std.fmt.bufPrint(buf, "{s}.sdx", .{stem}) catch unreachable; // unreachable: 64 bytes hold any segment's name
}

/// The amounts of `id`'s records from `from` on, in order.
fn amounts(journal: *Journal, id: []const u8, from: StreamVersion, out: []u32) ![]u32 {
    const io = testing.io;
    const walk = try journal.readStream(io, stream(id), from);
    defer walk.deinit();
    var n: usize = 0;
    var expect_version: ?u64 = null;
    while (try walk.next(io)) |record| {
        const at = record.stream.?;
        try testing.expectEqualStrings(id, at.id);
        if (expect_version) |v| try testing.expectEqual(v, at.version.raw());
        expect_version = at.version.raw() + 1;
        out[n] = record.event.deposited.amount;
        n += 1;
    }
    return out[0..n];
}

test "each stream numbers its own records, and a record carries its stream inside its checksum" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, .{});
    defer journal.deinit(io);

    const a1 = try journal.appendTo(io, stream("acct-a"), .no_stream, .fromRaw(1), deposit(10));
    const b1 = try journal.appendTo(io, stream("acct-b"), .any, .fromRaw(2), deposit(20));
    _ = try journal.append(io, .fromRaw(3), deposit(99));
    const a2 = try journal.appendTo(io, stream("acct-a"), .{ .exact = .fromRaw(1) }, .fromRaw(4), deposit(11));
    try testing.expectEqual(Seq.fromRaw(1), a1.seq);
    try testing.expectEqual(StreamVersion.fromRaw(1), a1.version);
    try testing.expectEqual(StreamVersion.fromRaw(1), b1.version);
    try testing.expectEqual(Seq.fromRaw(4), a2.seq);
    try testing.expectEqual(StreamVersion.fromRaw(2), a2.version);

    // The global sequence holds every record; each says its stream.
    const walk = try journal.replay(io, chronicle.beginning);
    defer walk.deinit(io);
    var streams_seen: [4]?u64 = undefined;
    var n: usize = 0;
    while (try walk.next(io)) |record| : (n += 1) {
        streams_seen[n] = if (record.stream) |at| at.version.raw() else null;
        if (record.stream) |at| try testing.expect(std.mem.find(u8, record.bytes, at.id) != null);
    }
    try testing.expectEqual(4, n);
    try testing.expectEqual(@as(?u64, null), streams_seen[2]);
    try testing.expectEqual(@as(?u64, 2), streams_seen[3]);

    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 10, 11 }, try amounts(journal, "acct-a", chronicle.no_version, &buf));
    try testing.expectEqualSlices(u32, &.{11}, try amounts(journal, "acct-a", .fromRaw(2), &buf));
    try testing.expectEqualSlices(u32, &.{20}, try amounts(journal, "acct-b", chronicle.no_version, &buf));
    try testing.expectEqualSlices(u32, &.{}, try amounts(journal, "acct-c", chronicle.no_version, &buf));
    try testing.expectEqual(StreamVersion.fromRaw(2), try journal.streamVersion(io, stream("acct-a")));
    try testing.expectEqual(chronicle.no_version, try journal.streamVersion(io, stream("acct-c")));
}

test "an append that expects what the stream does not hold writes nothing" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, .{});
    defer journal.deinit(io);

    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("s"), .exists, .fromRaw(1), deposit(1)));
    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("s"), .{ .exact = .fromRaw(1) }, .fromRaw(1), deposit(1)));
    _ = try journal.appendTo(io, stream("s"), .no_stream, .fromRaw(1), deposit(1));
    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("s"), .no_stream, .fromRaw(2), deposit(2)));
    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("s"), .{ .exact = .fromRaw(2) }, .fromRaw(2), deposit(2)));
    _ = try journal.appendTo(io, stream("s"), .exists, .fromRaw(2), deposit(2));
    try testing.expectEqual(Seq.fromRaw(2), try journal.lastSeq(io));
    try testing.expectEqual(StreamVersion.fromRaw(2), try journal.streamVersion(io, stream("s")));
}

test "a stream's records in sealed segments are found through their stream indexes, after a reopen too" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(3) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..10) |i| {
            const id: []const u8 = if (i % 2 == 0) "even" else "odd";
            _ = try journal.appendTo(io, stream(id), .any, .fromRaw(@intCast(i)), deposit(@intCast(i)));
        }
        try testing.expect(try journal.segmentCount(io) >= 3);
        var buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6, 8 }, try amounts(journal, "even", chronicle.no_version, &buf));
    }
    // Every sealed segment has its stream index.
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
    defer dir.close(io);
    var sidecars: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".sdx")) sidecars += 1;
    }
    try testing.expect(sidecars >= 2);

    const journal = try Journal.open(testing.allocator, io, place.path, options);
    defer journal.deinit(io);
    try testing.expectEqual(StreamVersion.fromRaw(5), try journal.streamVersion(io, stream("even")));
    try testing.expectEqual(StreamVersion.fromRaw(5), try journal.streamVersion(io, stream("odd")));
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 7, 9 }, try amounts(journal, "odd", chronicle.no_version, &buf));
    try testing.expectEqualSlices(u32, &.{ 7, 9 }, try amounts(journal, "odd", .fromRaw(4), &buf));
    const next = try journal.appendTo(io, stream("odd"), .{ .exact = .fromRaw(5) }, .fromRaw(10), deposit(10));
    try testing.expectEqual(StreamVersion.fromRaw(6), next.version);
}

test "a stream index that is missing or damaged is rebuilt from its segment" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(2) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..6) |i| _ = try journal.appendTo(io, stream("s"), .any, .fromRaw(@intCast(i)), deposit(@intCast(i)));
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
    defer dir.close(io);
    var name: [64]u8 = undefined;
    try dir.deleteFile(io, sdxName(&name, 1));
    try dir.writeFile(io, .{ .sub_path = sdxName(&name, 3), .data = "not an index" });

    const journal = try Journal.open(testing.allocator, io, place.path, options);
    defer journal.deinit(io);
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, try amounts(journal, "s", chronicle.no_version, &buf));
}

test "streams past the heads kept in memory are found in the segments, each at its version" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, .{ .max_segment_records = .fromRaw(4), .stream_heads = 2 });
    defer journal.deinit(io);
    var name: [16]u8 = undefined;
    for (0..3) |round| {
        for (0..12) |i| {
            const id = try std.fmt.bufPrint(&name, "s{d}", .{i});
            const appended = try journal.appendTo(io, stream(id), .{ .exact = .fromRaw(round) }, .fromRaw(0), deposit(@intCast(i)));
            try testing.expectEqual(StreamVersion.fromRaw(round + 1), appended.version);
        }
    }
    for (0..12) |i| {
        const id = try std.fmt.bufPrint(&name, "s{d}", .{i});
        try testing.expectEqual(StreamVersion.fromRaw(3), try journal.streamVersion(io, stream(id)));
    }
    try testing.expectEqual(chronicle.no_version, try journal.streamVersion(io, stream("s12")));
}

test "a batch into a stream takes its next versions, all or none" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, .{});
    defer journal.deinit(io);
    const entries = [_]Journal.Entry{
        .{ .at = .fromRaw(1), .event = deposit(1) },
        .{ .at = .fromRaw(2), .event = deposit(2) },
        .{ .at = .fromRaw(3), .event = deposit(3) },
    };
    const last = try journal.appendAllTo(io, stream("b"), .no_stream, &entries, .atomic);
    try testing.expectEqual(StreamVersion.fromRaw(3), last.version);
    try testing.expectEqual(Seq.fromRaw(3), last.seq);
    try testing.expectError(error.WrongExpectedVersion, journal.appendAllTo(io, stream("b"), .{ .exact = .fromRaw(2) }, &entries, .atomic));
    const again = try journal.appendAllTo(io, stream("b"), .{ .exact = .fromRaw(3) }, entries[0..2], .group);
    try testing.expectEqual(StreamVersion.fromRaw(5), again.version);
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 1, 2 }, try amounts(journal, "b", chronicle.no_version, &buf));
}

test "a stream truncated before a version is read from there, keeps its version, and stays so after a reopen" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(3) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..6) |i| _ = try journal.appendTo(io, stream("person-7"), .any, .fromRaw(@intCast(i)), deposit(@intCast(i)));
        try journal.truncateStreamBefore(io, stream("person-7"), .fromRaw(5));
        var buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, &.{ 4, 5 }, try amounts(journal, "person-7", chronicle.no_version, &buf));
        try testing.expectError(error.StreamCompacted, journal.readStream(io, stream("person-7"), .fromRaw(2)));
        try testing.expectEqual(StreamVersion.fromRaw(6), try journal.streamVersion(io, stream("person-7")));
    }
    const journal = try Journal.open(testing.allocator, io, place.path, options);
    defer journal.deinit(io);
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, try amounts(journal, "person-7", chronicle.no_version, &buf));
    // Truncated past every record: the stream keeps its place.
    try journal.truncateStreamBefore(io, stream("person-7"), .fromRaw(7));
    try testing.expectEqualSlices(u32, &.{}, try amounts(journal, "person-7", chronicle.no_version, &buf));
    try testing.expectEqual(StreamVersion.fromRaw(6), try journal.streamVersion(io, stream("person-7")));
    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("person-7"), .no_stream, .fromRaw(9), deposit(9)));
    const after = try journal.appendTo(io, stream("person-7"), .{ .exact = .fromRaw(6) }, .fromRaw(9), deposit(9));
    try testing.expectEqual(StreamVersion.fromRaw(7), after.version);
}

test "a stream id is refused unless it has one plain spelling" {
    try testing.expectError(error.InvalidStream, Stream.of(""));
    try testing.expectError(error.InvalidStream, Stream.of("a\"b"));
    try testing.expectError(error.InvalidStream, Stream.of("new\nline"));
    _ = try Stream.of("order-7/line:2");
}

/// Every byte of the journal's segment files, concatenated.
fn segmentBytes(path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const io = testing.io;
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, chronicle.segment_extension)) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        defer gpa.free(bytes);
        try all.appendSlice(gpa, bytes);
    }
    return all.toOwnedSlice(gpa);
}

test "compaction takes a truncated stream's events out of the files and leaves each one's place, the chain whole" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(3) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..8) |i| {
            const id: []const u8 = if (i % 2 == 0) "person-7" else "keep";
            _ = try journal.appendTo(io, stream(id), .any, .fromRaw(@intCast(i)), deposit(@intCast(1000 + i)));
        }
        try journal.truncateStreamBefore(io, stream("person-7"), .fromRaw(4));
        // Until the compaction the events are still in the files.
        const before = try segmentBytes(place.path, testing.allocator);
        defer testing.allocator.free(before);
        try testing.expect(std.mem.find(u8, before, "1000") != null);

        try journal.compact(io, chronicle.beginning);
        const after = try segmentBytes(place.path, testing.allocator);
        defer testing.allocator.free(after);
        // person-7's versions 1 to 3 were the amounts 1000, 1002, 1004.
        for ([_][]const u8{ "1000", "1002", "1004" }) |gone| try testing.expect(std.mem.find(u8, after, gone) == null);
        try testing.expect(std.mem.find(u8, after, "1006") != null);
        try testing.expect(std.mem.find(u8, after, "\"chronicle\":2") != null);

        // The global walk steps over the stubs; the sequence keeps its places.
        const walk = try journal.replay(io, chronicle.beginning);
        defer walk.deinit(io);
        var seqs: [8]u64 = undefined;
        var n: usize = 0;
        while (try walk.next(io)) |record| : (n += 1) seqs[n] = record.seq.raw();
        try testing.expectEqualSlices(u64, &.{ 2, 4, 6, 7, 8 }, seqs[0..n]);
        var buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, &.{1006}, try amounts(journal, "person-7", chronicle.no_version, &buf));
        try testing.expectEqualSlices(u32, &.{ 1001, 1003, 1005, 1007 }, try amounts(journal, "keep", chronicle.no_version, &buf));
        _ = try journal.appendTo(io, stream("person-7"), .{ .exact = .fromRaw(4) }, .fromRaw(9), deposit(9));
    }
    // Reopened and checked through: every link holds across the stubs.
    var full = options;
    full.verify = .full;
    const journal = try Journal.open(testing.allocator, io, place.path, full);
    defer journal.deinit(io);
    try testing.expectEqual(Seq.fromRaw(9), try journal.lastSeq(io));
    try testing.expectEqual(StreamVersion.fromRaw(5), try journal.streamVersion(io, stream("person-7")));
}

test "a stream whose records are dropped with their segments keeps its version, and reads below what is left are refused" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(2) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        _ = try journal.appendTo(io, stream("old"), .no_stream, .fromRaw(1), deposit(1));
        _ = try journal.appendTo(io, stream("old"), .any, .fromRaw(2), deposit(2));
        _ = try journal.appendTo(io, stream("both"), .no_stream, .fromRaw(3), deposit(3));
        _ = try journal.appendTo(io, stream("both"), .any, .fromRaw(4), deposit(4));
        _ = try journal.appendTo(io, stream("both"), .any, .fromRaw(5), deposit(5));
        _ = try journal.append(io, .fromRaw(6), deposit(6));
        _ = try journal.append(io, .fromRaw(7), deposit(7));
        try testing.expect(try journal.dropSegmentsBefore(io, .fromRaw(4)) >= 2);
    }
    const journal = try Journal.open(testing.allocator, io, place.path, options);
    defer journal.deinit(io);
    try testing.expectEqual(StreamVersion.fromRaw(2), try journal.streamVersion(io, stream("old")));
    try testing.expectError(error.WrongExpectedVersion, journal.appendTo(io, stream("old"), .no_stream, .fromRaw(8), deposit(8)));
    try testing.expectError(error.StreamCompacted, journal.readStream(io, stream("both"), .fromRaw(1)));
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{5}, try amounts(journal, "both", chronicle.no_version, &buf));
    try testing.expectEqual(StreamVersion.fromRaw(3), try journal.streamVersion(io, stream("both")));
}

test "a backup carries the streams' truncation points" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const copy = try std.fmt.allocPrint(testing.allocator, "{s}-copy", .{place.path});
    defer testing.allocator.free(copy);
    {
        const journal = try Journal.open(testing.allocator, io, place.path, .{});
        defer journal.deinit(io);
        for (0..4) |i| _ = try journal.appendTo(io, stream("p"), .any, .fromRaw(@intCast(i)), deposit(@intCast(i)));
        try journal.truncateStreamBefore(io, stream("p"), .fromRaw(3));
        _ = try journal.backup(io, copy);
    }
    const journal = try Journal.open(testing.allocator, io, copy, .{});
    defer journal.deinit(io);
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, try amounts(journal, "p", chronicle.no_version, &buf));
}
