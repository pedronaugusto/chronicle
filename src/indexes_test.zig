//! Field indexes declared on a journal's event: written beside each sealed
//! segment as its records were appended, refused keys, the active segment
//! sealed early past its index memory, and the files going with their
//! segments.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");
const format = @import("journal/index.zig").format;

const index = chronicle.index;

const Event = union(enum) {
    paid: struct { account: u64, amount: i64, note: []const u8 = "" },
    closed: struct { account: u64 },

    pub const chronicle = .{ .indexes = &.{
        index("account", 1, .exact, accountOf),
        index("amount", 1, .ordered, amountOf),
        index("note", 1, .exact, noteOf),
    } };

    fn accountOf(e: Event) ?u64 {
        return switch (e) {
            inline else => |v| v.account,
        };
    }
    fn amountOf(e: Event) ?i64 {
        return switch (e) {
            .paid => |p| p.amount,
            .closed => null,
        };
    }
    fn noteOf(e: Event) ?[]const u8 {
        return switch (e) {
            .paid => |p| if (p.note.len == 0) null else p.note,
            .closed => null,
        };
    }
};

const Journal = chronicle.Journal(Event);

fn paid(account: u64, amount: i64) Event {
    return .{ .paid = .{ .account = account, .amount = amount } };
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

fn fileName(buf: []u8, base: u64, name: []const u8) []const u8 {
    return std.mem.print(buf, "{d:0>20}.{s}.cdx", .{ base, name }) catch unreachable; // unreachable: the tests give room
}

/// Segment `base`'s file of index `name`, parsed, or null when it has none.
fn readIndex(dir: Io.Dir, base: u64, name: []const u8, kind: format.Kind, bytes: *[]u8) !?format.Index {
    var name_buf: [64]u8 = undefined;
    bytes.* = dir.readFileAlloc(testing.io, fileName(&name_buf, base, name), testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const segment = try dir.readFileAlloc(testing.io, &chronicle.segmentName(.fromRaw(base)), testing.allocator, .unlimited);
    defer testing.allocator.free(segment);
    return try format.Index.parse(.init(bytes.*), .{ .base_seq = .fromRaw(base), .segment_bytes = .fromRaw(segment.len), .name = name, .version = 1, .kind = kind });
}

test "each sealed segment has its declared indexes beside it, holding its records by key" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    {
        const journal = try Journal.open(testing.allocator, io, place.path, .{ .max_segment_records = .fromRaw(3) });
        defer journal.deinit(io);
        // Segments 1-3, 4-6 and the active 7.
        const events = [_]Event{ paid(1, 10), paid(2, -5), .{ .closed = .{ .account = 1 } }, paid(1, 7), .{ .paid = .{ .account = 3, .amount = 0, .note = "rent" } }, paid(2, 10), paid(1, 1) };
        for (events) |e| _ = try journal.append(io, .fromRaw(0), e);
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{});
    defer dir.close(io);
    var bytes: []u8 = &.{};
    {
        const accounts = (try readIndex(dir, 1, "account", .exact, &bytes)).?;
        defer testing.allocator.free(bytes);
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, 1, .little);
        const run = accounts.find(&key);
        try testing.expectEqual(2, run.end - run.first);
        try testing.expectEqual(@as(u64, 1), accounts.at(run.first).seq.raw());
        try testing.expectEqual(@as(u64, 3), accounts.at(run.first + 1).seq.raw());
    }
    {
        const amounts = (try readIndex(dir, 4, "amount", .ordered, &bytes)).?;
        defer testing.allocator.free(bytes);
        const run = amounts.range(format.orderedKey(@as(i64, 5)), format.orderedKey(@as(i64, 100)));
        try testing.expectEqual(2, run.end - run.first);
        try testing.expectEqual(@as(u64, 4), amounts.at(run.first).seq.raw());
    }
    {
        const notes = (try readIndex(dir, 4, "note", .exact, &bytes)).?;
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(u32, 1), notes.keys);
        try testing.expectEqualStrings("rent", notes.keyAt(0));
    }
    // The active segment has none yet.
    try testing.expect(try readIndex(dir, 7, "account", .exact, &bytes) == null);
}

test "a key past 255 bytes refuses its record before anything is written" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, .{});
    defer journal.deinit(io);
    _ = try journal.append(io, .fromRaw(0), paid(1, 1));
    var long: [256]u8 = @splat('n');
    try testing.expectError(error.KeyTooLong, journal.append(io, .fromRaw(0), .{ .paid = .{ .account = 1, .amount = 1, .note = &long } }));
    const entries = [_]Journal.Entry{ .{ .at = .fromRaw(0), .event = paid(2, 2) }, .{ .at = .fromRaw(0), .event = .{ .paid = .{ .account = 1, .amount = 1, .note = &long } } } };
    try testing.expectError(error.KeyTooLong, journal.appendAll(io, &entries, .atomic));
    try testing.expectEqual(chronicle.Seq.fromRaw(1), try journal.lastSeq(io));
}

test "past its index memory the active segment is sealed early, each sealed one indexed whole" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    {
        // Room for about four records' entries and keys across the three indexes.
        const journal = try Journal.open(testing.allocator, io, place.path, .{ .index_memory = .fromRaw(4 * 3 * 32) });
        defer journal.deinit(io);
        for (0..20) |i| _ = try journal.append(io, .fromRaw(0), paid(i, @intCast(i)));
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
    defer dir.close(io);
    var segments: usize = 0;
    var walk = dir.iterate();
    while (try walk.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, chronicle.segment_extension)) segments += 1;
    }
    try testing.expect(segments > 2);
    var bytes: []u8 = &.{};
    const first = (try readIndex(dir, 1, "account", .exact, &bytes)).?;
    defer testing.allocator.free(bytes);
    try testing.expect(first.postings > 0);
}

test "a segment open before the journal was seals without index files; the next has them; a dropped segment takes its files" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(2) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        _ = try journal.append(io, .fromRaw(0), paid(1, 1));
    }
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..4) |i| _ = try journal.append(io, .fromRaw(0), paid(i, 1));
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{});
    defer dir.close(io);
    var bytes: []u8 = &.{};
    // Segment 1 held a record when the second open found it: its records were not all noted.
    try testing.expect(try readIndex(dir, 1, "account", .exact, &bytes) == null);
    const second = (try readIndex(dir, 3, "account", .exact, &bytes)).?;
    testing.allocator.free(bytes);
    try testing.expectEqual(@as(u32, 2), second.postings);
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        _ = try journal.dropSegmentsBefore(io, .fromRaw(5));
    }
    try testing.expect(try readIndex(dir, 3, "account", .exact, &bytes) == null);
}

test "a cut inside a sealed segment removes its index files, which appends could bring back to the segment's length" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const options: Journal.Options = .{ .max_segment_records = .fromRaw(3) };
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        for (0..4) |i| _ = try journal.append(io, .fromRaw(0), paid(i, 1));
        var dir = try Io.Dir.cwd().openDir(io, place.path, .{});
        defer dir.close(io);
        var bytes: []u8 = &.{};
        const sealed = (try readIndex(dir, 1, "account", .exact, &bytes)).?;
        testing.allocator.free(bytes);
        try testing.expectEqual(@as(u32, 3), sealed.postings);
        try journal.truncateAfter(io, .fromRaw(2));
        var name_buf: [64]u8 = undefined;
        for ([_][]const u8{ "account", "amount" }) |name| {
            try testing.expectError(error.FileNotFound, dir.access(io, fileName(&name_buf, 1, name), .{}));
        }
        // The same record again: segment 1 is as long as it was, with other contents.
        _ = try journal.append(io, .fromRaw(0), paid(7, 1));
    }
}
