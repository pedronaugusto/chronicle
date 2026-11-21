//! Reads by key (`readIndexed`, `readRange`): for random journals, every
//! read equals filtering a full replay by the key, from any position, and
//! again from where a read stopped, through appends, atomic batches, seals,
//! reopens, cuts, compactions, and index files removed, cut short, damaged,
//! swapped, or lying with their checksums whole.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const chronicle = @import("chronicle.zig");
const format = @import("journal/index.zig").format;

const gen = shakedown.gen;
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
/// Three records a segment, so a few appends cross several; no sync, which the reads do not depend on.
const options: Journal.Options = .{ .max_segment_records = .fromRaw(3), .sync = .never };

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

/// What a read asks, as the model filters a replay by it.
const Query = union(enum) {
    account: u64,
    amounts: struct { lo: i64, hi: i64 },
    note: []const u8,

    fn holds(q: Query, e: Event) bool {
        return switch (q) {
            .account => |a| Event.accountOf(e).? == a,
            .amounts => |r| if (Event.amountOf(e)) |v| r.lo <= v and v <= r.hi else false,
            .note => |n| if (Event.noteOf(e)) |v| std.mem.eql(u8, v, n) else false,
        };
    }

    fn read(q: Query, journal: *Journal, io: Io, from: chronicle.Position) !*Journal.Replay {
        return switch (q) {
            .account => |a| journal.readIndexed(io, "account", a, from),
            .amounts => |r| journal.readRange(io, "amount", r.lo, r.hi, from),
            .note => |n| journal.readIndexed(io, "note", n, from),
        };
    }
};

const notes = [_][]const u8{ "", "a", "b" };

fn drawQuery(s: *shakedown.Source) Query {
    return switch (gen.intRange(s, u8, 0, 2)) {
        0 => .{ .account = gen.intRange(s, u64, 0, 4) },
        1 => .{ .amounts = .{ .lo = gen.intRange(s, i64, -6, 6), .hi = gen.intRange(s, i64, -6, 6) } },
        else => .{ .note = notes[gen.intRange(s, usize, 0, notes.len - 1)] },
    };
}

fn drawEvent(s: *shakedown.Source) Event {
    if (gen.intRange(s, u8, 0, 4) == 0) return .{ .closed = .{ .account = gen.intRange(s, u64, 0, 4) } };
    return .{ .paid = .{ .account = gen.intRange(s, u64, 0, 4), .amount = gen.intRange(s, i64, -5, 5), .note = notes[gen.intRange(s, usize, 0, notes.len - 1)] } };
}

/// The seqs a full replay after `cursor` gives that `q` asks for.
fn modelled(journal: *Journal, io: Io, cursor: chronicle.Seq, q: Query, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    const walk = try journal.replay(io, cursor);
    defer walk.deinit(io);
    while (try walk.next(io)) |r| if (q.holds(r.event)) try out.append(testing.allocator, r.seq.raw());
}

/// The seqs a read gives, at most `limit` of them.
fn readSeqs(walk: *Journal.Replay, io: Io, q: Query, limit: usize, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    while (out.items.len < limit) {
        const r = try walk.next(io) orelse break;
        // Every record handed on has the key asked.
        try testing.expect(q.holds(r.event));
        try out.append(testing.allocator, r.seq.raw());
    }
}

/// One of the index files in `dir` cut short, flipped, or replaced by
/// another's, so that it no longer describes its segment.
fn damage(s: *shakedown.Source, io: Io, dir: Io.Dir) !void {
    const gpa = testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".cdx")) try names.append(gpa, try gpa.dupe(u8, entry.name));
    if (names.items.len == 0) return;
    std.sort.pdq([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    const victim = names.items[gen.intRange(s, usize, 0, names.items.len - 1)];
    const bytes = try dir.readFileAlloc(io, victim, gpa, .unlimited);
    defer gpa.free(bytes);
    switch (gen.intRange(s, u8, 0, 3)) {
        0 => try dir.writeFile(io, .{ .sub_path = victim, .data = bytes[0 .. bytes.len / 2] }),
        1 => {
            bytes[gen.intRange(s, usize, 0, bytes.len - 1)] ^= 0x40;
            try dir.writeFile(io, .{ .sub_path = victim, .data = bytes });
        },
        2 => {
            const other = names.items[gen.intRange(s, usize, 0, names.items.len - 1)];
            const theirs = try dir.readFileAlloc(io, other, gpa, .unlimited);
            defer gpa.free(theirs);
            try dir.writeFile(io, .{ .sub_path = victim, .data = theirs });
        },
        else => try dir.deleteFile(io, victim),
    }
}

fn modelOne(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    var journal = try Journal.open(gpa, io, place.path, options);
    defer journal.deinit(io);
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
    defer dir.close(io);

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(gpa);
    var rest: std.ArrayList(u64) = .empty;
    defer rest.deinit(gpa);

    for (0..gen.intRange(s, usize, 1, 30)) |_| {
        switch (gen.intRange(s, u8, 0, 10)) {
            0...3 => _ = try journal.append(io, .fromRaw(0), drawEvent(s)),
            4 => {
                var entries: [4]Journal.Entry = undefined;
                const n = gen.intRange(s, usize, 1, entries.len);
                for (entries[0..n]) |*e| e.* = .{ .at = .fromRaw(0), .event = drawEvent(s) };
                _ = try journal.appendAll(io, entries[0..n], if (gen.boolean(s)) .atomic else .group);
            },
            5 => {
                journal.deinit(io);
                journal = try Journal.open(gpa, io, place.path, options);
            },
            6 => {
                const last = try journal.lastSeq(io);
                // Up to three records back, and no further than the first.
                const cut = last.retreat(.fromRaw(gen.intRange(s, u64, 0, 3))) catch chronicle.Seq.fromRaw(0);
                journal.truncateAfter(io, cut) catch |err| switch (err) {
                    error.SeqTooOld => {},
                    else => |e| return e,
                };
            },
            7 => {
                const last = (try journal.lastSeq(io)).raw();
                try journal.compact(io, .fromRaw(gen.intRange(s, u64, 0, last)));
            },
            10 => {
                // Built to the end: then no sealed segment lacks a file.
                var calls: usize = 0;
                while (try journal.buildIndexes(io)) |_| {
                    calls += 1;
                    // One segment a call: never more calls than segments.
                    try testing.expect(calls <= 64);
                }
                const status = try journal.indexStatus(io);
                for (status.indexes) |each| try testing.expectEqual(0, each.missing);
            },
            else => {
                try damage(s, io, dir);
                // A journal that read the file before keeps its summary: a
                // reopen reads the damaged one.
                if (gen.boolean(s)) {
                    journal.deinit(io);
                    journal = try Journal.open(gpa, io, place.path, options);
                }
            },
        }
        // Reads between the changes, so summaries are kept across them.
        if (gen.boolean(s)) {
            const q = drawQuery(s);
            try modelled(journal, io, .fromRaw(0), q, &want);
            const walk = try q.read(journal, io, .after(.fromRaw(0)));
            defer walk.deinit(io);
            try readSeqs(walk, io, q, std.math.maxInt(usize), &got);
            try testing.expectEqualSlices(u64, want.items, got.items);
        }
    }

    for (0..4) |_| {
        const q = drawQuery(s);
        const last = (try journal.lastSeq(io)).raw();
        const cursor: chronicle.Seq = .fromRaw(gen.intRange(s, u64, 0, last));
        try modelled(journal, io, cursor, q, &want);
        // Part of the read, then the rest from its position, both ways.
        const walk = try q.read(journal, io, .after(cursor));
        defer walk.deinit(io);
        const first = gen.intRange(s, usize, 0, want.items.len);
        try readSeqs(walk, io, q, first, &got);
        try testing.expectEqualSlices(u64, want.items[0..got.items.len], got.items);
        const position = walk.position();
        const again = try q.read(journal, io, position);
        defer again.deinit(io);
        try readSeqs(again, io, q, std.math.maxInt(usize), &rest);
        try testing.expectEqualSlices(u64, want.items[got.items.len..], rest.items);
        try walk.rearmAt(io, position);
        try readSeqs(walk, io, q, std.math.maxInt(usize), &rest);
        try testing.expectEqualSlices(u64, want.items[got.items.len..], rest.items);
    }
}

test "every read by key or range equals a full replay filtered by it, from any position, whatever happened to the index files" {
    try shakedown.check(testing.allocator, {}, modelOne, .{
        .seed = 0x72656164,
        .cases = 150,
        .regressions = &.{
            // A cut that left a sealed segment active, its earlier records never noted in its indexes.
            "4:4:1:0:0:0:0:0:0:0:0:0:0:0:0:0:0:6:2",
            // A cut inside a sealed segment, and appends that brought it back to its length with other
            // records, under the index files it had kept.
            "10:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:6:3:0:0:0:3:0:0:0:0:1:0:3",
        },
    });
}

test "a read's key is the index's own type, and an ordered index is read by one key or a range" {
    try testing.expectEqual(u64, Journal.KeyOf("account"));
    try testing.expectEqual(i64, Journal.KeyOf("amount"));
    try testing.expectEqual([]const u8, Journal.KeyOf("note"));
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(testing.allocator, io, place.path, options);
    defer journal.deinit(io);
    for (0..7) |i| _ = try journal.append(io, .fromRaw(0), .{ .paid = .{ .account = i % 2, .amount = @as(i64, @intCast(i)) - 3 } });
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(testing.allocator);
    {
        const walk = try journal.readIndexed(io, "amount", 0, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try readSeqs(walk, io, .{ .amounts = .{ .lo = 0, .hi = 0 } }, 10, &got);
        try testing.expectEqualSlices(u64, &.{4}, got.items);
    }
    {
        // Lowest above highest: nothing.
        const walk = try journal.readRange(io, "amount", 2, -2, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try testing.expect(try walk.next(io) == null);
    }
    {
        // A key longer than any record's can be: nothing.
        var long: [256]u8 = @splat('n');
        const walk = try journal.readIndexed(io, "note", &long, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try testing.expect(try walk.next(io) == null);
    }
}

/// The offsets of segment `base`'s records' lines, in order.
fn lineStarts(io: Io, dir: Io.Dir, base: u64, out: []u64) !usize {
    const bytes = try dir.readFileAlloc(io, &chronicle.segmentName(.fromRaw(base)), testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    var n: usize = 0;
    var at: usize = (std.mem.findScalar(u8, bytes, '\n') orelse return 0) + 1;
    while (at < bytes.len and n < out.len) : (n += 1) {
        out[n] = at;
        at += (std.mem.findScalar(u8, bytes[at..], '\n') orelse break) + 1;
    }
    return n;
}

test "an index whose checksum holds but whose postings name records without the key is not believed: its segment is read whole" {
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    {
        const journal = try Journal.open(gpa, io, place.path, options);
        defer journal.deinit(io);
        // Segment 1 holds accounts 1, 2, 1; segment 4 the active one.
        for ([_]u64{ 1, 2, 1, 2 }) |a| _ = try journal.append(io, .fromRaw(0), .{ .closed = .{ .account = a } });
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{});
    defer dir.close(io);
    var starts: [3]u64 = undefined;
    try testing.expectEqual(3, try lineStarts(io, dir, 1, &starts));
    const segment = try dir.readFileAlloc(io, &chronicle.segmentName(.fromRaw(1)), gpa, .unlimited);
    const segment_bytes = segment.len;
    gpa.free(segment);
    // A lie for account 1: its first record is seq 2 (account 2), and seq 3 is left out.
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .little);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try format.encode(gpa, .{ .base_seq = .fromRaw(1), .segment_bytes = .fromRaw(segment_bytes), .name = "account", .version = 1, .kind = .exact }, &.{.exact(&key, .fromRaw(2), .fromRaw(starts[1]), 0)}, &out);
    try dir.writeFile(io, .{ .sub_path = "00000000000000000001.account.cdx", .data = out.items });

    const journal = try Journal.open(gpa, io, place.path, options);
    defer journal.deinit(io);
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(gpa);
    for (0..2) |_| {
        // Twice: the second read passes the lying file over for its summary's stale mark.
        const walk = try journal.readIndexed(io, "account", 1, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try readSeqs(walk, io, .{ .account = 1 }, 10, &got);
        try testing.expectEqualSlices(u64, &.{ 1, 3 }, got.items);
    }
}

test "a read stopped at a position whose record has changed is StalePosition" {
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(gpa, io, place.path, options);
    defer journal.deinit(io);
    for (0..5) |_| _ = try journal.append(io, .fromRaw(0), .{ .closed = .{ .account = 1 } });
    const walk = try journal.readIndexed(io, "account", 1, .after(.fromRaw(0)));
    defer walk.deinit(io);
    for (0..5) |_| _ = (try walk.next(io)).?;
    const position = walk.position();
    try journal.truncateAfter(io, .fromRaw(3));
    for (0..2) |_| _ = try journal.append(io, .fromRaw(0), .{ .closed = .{ .account = 2 } });
    try testing.expectError(error.StalePosition, journal.readIndexed(io, "account", 1, position));
    try testing.expectError(error.StalePosition, walk.rearmAt(io, position));
}

/// `Event` as a journal without indexes writes it: the same records.
const Plain = union(enum) {
    paid: struct { account: u64, amount: i64, note: []const u8 = "" },
    closed: struct { account: u64 },
};

test "indexes declared on a journal that holds records: reads are right before they are built, and buildIndexes builds them a segment a call" {
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    {
        const plain = try chronicle.Journal(Plain).open(gpa, io, place.path, .{ .max_segment_records = .fromRaw(3), .sync = .never });
        defer plain.deinit(io);
        // Segments 1 and 4 sealed, 7 active.
        for (0..7) |i| _ = try plain.append(io, .fromRaw(0), .{ .paid = .{ .account = i % 3, .amount = @intCast(i) } });
    }
    const journal = try Journal.open(gpa, io, place.path, options);
    defer journal.deinit(io);
    var status = try journal.indexStatus(io);
    try testing.expectEqualStrings("amount", status.indexes[1].name);
    for (status.indexes) |each| try testing.expect(each.indexed == 0 and each.missing == 2);

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(gpa);
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(gpa);
    const q: Query = .{ .account = 1 };
    try modelled(journal, io, .fromRaw(0), q, &want);
    try testing.expectEqualSlices(u64, &.{ 2, 5 }, want.items);
    {
        const walk = try q.read(journal, io, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try readSeqs(walk, io, q, 10, &got);
        try testing.expectEqualSlices(u64, want.items, got.items);
    }
    // Both sealed segments read whole, and the active one, whose indexes in memory the reopen left stale.
    status = try journal.indexStatus(io);
    try testing.expectEqual(3, status.indexes[0].scanned);

    try testing.expectEqual(Journal.BuildProgress{ .segment = .fromRaw(1), .left = 1 }, (try journal.buildIndexes(io)).?);
    try testing.expectEqual(Journal.BuildProgress{ .segment = .fromRaw(4), .left = 0 }, (try journal.buildIndexes(io)).?);
    try testing.expect(try journal.buildIndexes(io) == null);
    status = try journal.indexStatus(io);
    for (status.indexes) |each| try testing.expect(each.indexed == 2 and each.missing == 0 and each.rebuilt == 2);
    {
        const walk = try q.read(journal, io, .after(.fromRaw(0)));
        defer walk.deinit(io);
        try readSeqs(walk, io, q, 10, &got);
        try testing.expectEqualSlices(u64, want.items, got.items);
    }
    // Only the active segment was read whole this time.
    status = try journal.indexStatus(io);
    try testing.expectEqual(4, status.indexes[0].scanned);
}

test "a version raised makes every file of the index stale, and buildIndexes writes them again" {
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    {
        const journal = try Journal.open(gpa, io, place.path, options);
        defer journal.deinit(io);
        for (0..7) |i| _ = try journal.append(io, .fromRaw(0), .{ .closed = .{ .account = i } });
        const status = try journal.indexStatus(io);
        try testing.expect(status.indexes[0].indexed == 2 and status.indexes[0].missing == 0);
    }
    const Raised = union(enum) {
        paid: struct { account: u64, amount: i64, note: []const u8 = "" },
        closed: struct { account: u64 },

        pub const chronicle = .{ .indexes = &.{
            index("account", 2, .exact, accountOf),
            index("amount", 1, .ordered, amountOf),
        } };

        fn accountOf(e: @This()) ?u64 {
            return switch (e) {
                inline else => |v| v.account,
            };
        }
        fn amountOf(e: @This()) ?i64 {
            return switch (e) {
                .paid => |p| p.amount,
                .closed => null,
            };
        }
    };
    const journal = try chronicle.Journal(Raised).open(gpa, io, place.path, .{ .max_segment_records = .fromRaw(3), .sync = .never });
    defer journal.deinit(io);
    var status = try journal.indexStatus(io);
    try testing.expect(status.indexes[0].missing == 2 and status.indexes[1].indexed == 2);
    var calls: usize = 0;
    while (try journal.buildIndexes(io)) |_| calls += 1;
    try testing.expectEqual(2, calls);
    status = try journal.indexStatus(io);
    try testing.expect(status.indexes[0].indexed == 2 and status.indexes[0].rebuilt == 2 and status.indexes[1].rebuilt == 0);
}

test "a journal opened to read builds no index" {
    const io = testing.io;
    var place = try Place.init();
    defer place.deinit();
    {
        const journal = try Journal.open(testing.allocator, io, place.path, options);
        defer journal.deinit(io);
        _ = try journal.append(io, .fromRaw(0), .{ .closed = .{ .account = 1 } });
    }
    var read_options = options;
    read_options.access = .read;
    const journal = try Journal.open(testing.allocator, io, place.path, read_options);
    defer journal.deinit(io);
    try testing.expectError(error.ReadOnly, journal.buildIndexes(io));
}

test "a segment's index files built from it are the files its seal wrote, byte for byte" {
    const io = testing.io;
    const gpa = testing.allocator;
    var place = try Place.init();
    defer place.deinit();
    const journal = try Journal.open(gpa, io, place.path, options);
    defer journal.deinit(io);
    var prng: std.Random.DefaultPrng = .init(0x6275696c);
    for (0..10) |_| {
        const r = prng.random();
        _ = try journal.append(io, .fromRaw(0), .{ .paid = .{ .account = r.uintLessThan(u64, 4), .amount = r.intRangeAtMost(i64, -3, 3), .note = notes[r.uintLessThan(usize, notes.len)] } });
    }
    var dir = try Io.Dir.cwd().openDir(io, place.path, .{});
    defer dir.close(io);
    const names = [_][]const u8{ "00000000000000000001.account.cdx", "00000000000000000004.amount.cdx", "00000000000000000007.note.cdx" };
    var sealed: [names.len][]u8 = undefined;
    for (names, &sealed) |name, *bytes| {
        bytes.* = try dir.readFileAlloc(io, name, gpa, .unlimited);
        try dir.deleteFile(io, name);
    }
    defer for (sealed) |bytes| gpa.free(bytes);
    // The journal holds the summaries of none of them, so it finds them gone.
    while (try journal.buildIndexes(io)) |_| {}
    for (names, sealed) |name, bytes| {
        const built = try dir.readFileAlloc(io, name, gpa, .unlimited);
        defer gpa.free(built);
        try testing.expectEqualSlices(u8, bytes, built);
    }
}
