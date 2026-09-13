//! The suite. Every test opens a real journal on a real directory through
//! `std.testing.io`, because what this package promises is about files.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");

/// The events of a tiny registry: enough shape to fold, and an `unknown` arm
/// so a record from an older schema has somewhere to land.
const Event = union(enum) {
    created: struct { id: u32, name: []const u8 },
    renamed: struct { id: u32, name: []const u8 },
    removed: struct { id: u32 },
    unknown: std.json.Value,
};

const Journal = chronicle.Journal(Event);

/// A fold: the state the log adds up to. Two folds of the same records are
/// equal whether the records came off the disk or arrived live, which is what
/// several tests below check.
const Registry = struct {
    live: u32 = 0,
    events: u32 = 0,
    unknown: u32 = 0,
    names: u64 = 0,
    last: u64 = 0,

    fn sink(self: *Registry) Journal.Sink {
        return .{ .ctx = self, .f = apply };
    }

    fn apply(ctx: *anyopaque, record: Journal.Record) void {
        const self: *Registry = @ptrCast(@alignCast(ctx));
        self.events += 1;
        self.last = record.seq;
        switch (record.event) {
            .created => |e| {
                self.live += 1;
                self.names ^= std.hash.Wyhash.hash(e.id, e.name);
            },
            .renamed => |e| self.names ^= std.hash.Wyhash.hash(e.id, e.name),
            .removed => self.live -= 1,
            .unknown => self.unknown += 1,
        }
    }
};

fn created(id: u32, name: []const u8) Event {
    return .{ .created = .{ .id = id, .name = name } };
}

/// A temporary directory plus the absolute path of a journal inside it, torn
/// down together. `sub` names a file relative to the temporary directory, so a
/// test can write the file shapes a crash produces and open them.
const Workspace = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    path: []const u8,

    fn init(name: []const u8) !Workspace {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
        const path = try std.fs.path.join(arena.allocator(), &.{ root, name });
        return .{ .tmp = tmp, .arena = arena, .name = name, .path = path };
    }

    fn deinit(self: *Workspace) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// `<journal>/<file>`, relative to the temporary directory.
    fn sub(self: *Workspace, file: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.name, file });
    }

    fn segment(self: *Workspace, base_seq: u64) ![]const u8 {
        return self.sub(&chronicle.segmentName(base_seq));
    }

    fn index(self: *Workspace, base_seq: u64) ![]const u8 {
        var name = chronicle.segmentName(base_seq);
        @memcpy(name[name.len - 4 ..], chronicle.index_extension);
        return self.sub(&name);
    }

    fn read(self: *Workspace, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, self.arena.allocator(), .unlimited);
    }

    fn write(self: *Workspace, sub_path: []const u8, data: []const u8) !void {
        self.tmp.dir.createDirPath(testing.io, self.name) catch {};
        return self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn exists(self: *Workspace, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }
};

//========================================================================
// The shape of the thing on the disk.
//========================================================================

test "an append returns the sequence number and puts one line in the first segment" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);

    try testing.expectEqual(@as(u64, 1), try journal.append(io, 1_000, created(1, "one")));
    try testing.expectEqual(@as(u64, 2), try journal.append(io, 2_000, created(2, "two")));

    // The line on the disk, checksum and all. `c` is the CRC32C of everything
    // before it, so the literal here is also the definition of the format.
    const on_disk = try ws.read(try ws.segment(1));
    try testing.expectEqualStrings(
        \\{"seq":1,"at":1000,"v":1,"ev":{"created":{"id":1,"name":"one"}},"c":294682814}
        \\{"seq":2,"at":2000,"v":1,"ev":{"created":{"id":2,"name":"two"}},"c":1207820849}
        \\
    , on_disk);
    try testing.expectEqual(
        @as(u32, 294682814),
        chronicle.checksum(
            \\{"seq":1,"at":1000,"v":1,"ev":{"created":{"id":1,"name":"one"}}
        ),
    );

    // The record in memory is the line on the disk, parsed.
    const all = journal.records();
    try testing.expect(all.complete);
    try testing.expectEqual(@as(usize, 2), all.records.len);
    try testing.expectEqualStrings("two", all.records[1].event.created.name);
    try testing.expectEqual(@as(i64, 2_000), all.records[1].at);

    // A cursor is where a reader got to, so `since` is the rest of the log --
    // and a cursor past the end is a reader ahead of this process, not an
    // error.
    try testing.expectEqual(@as(usize, 1), journal.since(1).records.len);
    try testing.expectEqual(@as(usize, 0), journal.since(2).records.len);
    try testing.expectEqual(@as(usize, 0), journal.since(99).records.len);
    try testing.expect(journal.since(99).complete);

    // The directory is meant to be read by a person: one lock, one segment,
    // one index.
    try testing.expect(ws.exists(try ws.sub(chronicle.lock_name)));
    try testing.expect(ws.exists(try ws.index(1)));
    try testing.expectEqual(@as(usize, 1), journal.segmentCount());
}

test "a reopened journal continues the sequence and appends after the last line" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var first = try Journal.open(testing.allocator, io, ws.path, .{});
        defer first.deinit(io);
        _ = try first.append(io, 1, created(1, "before"));
        _ = try first.append(io, 2, created(2, "also before"));
    }

    var second = try Journal.open(testing.allocator, io, ws.path, .{});
    defer second.deinit(io);
    try testing.expectEqual(@as(u64, 2), try second.lastSeq(io));
    try testing.expectEqual(@as(usize, 2), second.records().records.len);
    try testing.expectEqualStrings("before", second.records().records[0].event.created.name);

    // Two records sharing a number would make a cursor ambiguous, so the seq
    // continues rather than starting again -- and the line lands after the
    // history rather than over it.
    try testing.expectEqual(@as(u64, 3), try second.append(io, 3, created(3, "after")));
    const on_disk = try ws.read(try ws.segment(1));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, on_disk, "\n"));
    try testing.expect(std.mem.indexOf(u8, on_disk, "\"seq\":3") != null);
}

//========================================================================
// The crash cases.
//========================================================================

test "a final line the writer did not finish is dropped and the segment repaired" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    const whole =
        \\{"seq":1,"at":1,"v":1,"ev":{"created":{"id":1,"name":"kept"}}}
        \\
    ;
    const partial = "{\"seq\":2,\"at\":2,\"v\":1,\"ev\":{\"crea";
    try ws.write(try ws.segment(1), whole ++ partial);

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);

        try testing.expectEqual(@as(usize, partial.len), journal.dropped_bytes);
        try testing.expectEqual(@as(usize, 1), journal.records().records.len);
        try testing.expectEqual(@as(u64, 1), try journal.lastSeq(io));

        // Repaired means the next append is well formed, not merely that this
        // process ignored the tail.
        _ = try journal.append(io, 3, created(2, "next"));
        const on_disk = try ws.read(try ws.segment(1));
        try testing.expect(std.mem.indexOf(u8, on_disk, "crea\"") == null);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, on_disk, "\n"));
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{});
    defer reopened.deinit(io);
    try testing.expectEqual(@as(usize, 2), reopened.records().records.len);
    try testing.expectEqual(@as(usize, 0), reopened.dropped_bytes);
}

test "on_truncated .fail refuses the journal and leaves the segment as found" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    const bytes = "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n{\"seq\":2";
    try ws.write(try ws.segment(1), bytes);
    try testing.expectError(
        error.TruncatedRecord,
        Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail }),
    );
    try testing.expectEqualStrings(bytes, try ws.read(try ws.segment(1)));
}

test "a torn line in a sealed segment is refused when something reads it" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // Only the newest segment can end mid-record: an older one was made
    // durable before the next was created. A hole in one is damage.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n" ++
        "{\"seq\":2,\"at\":1,\"v\":1,\"ev\":{\"remo");
    try ws.write(try ws.segment(3), "{\"seq\":3,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try testing.expectError(
        error.TruncatedRecord,
        Journal.open(testing.allocator, io, ws.path, .{}),
    );
}

test "a corrupt or discontinuous line is refused" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    const cases = [_]struct { bytes: []const u8, want: anyerror }{
        .{ .bytes = "not json\n", .want = error.CorruptRecord },
        .{ .bytes = "{\"seq\":1,\"at\":1,\"v\":1}\n", .want = error.CorruptRecord },
        .{ .bytes = "{\"seq\":2,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n" ++
            "{\"seq\":4,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n", .want = error.DiscontinuousSeq },
        // A segment whose records disagree with the name it is under: a
        // cursor into it would point at a record that is not there.
        .{ .bytes = "{\"seq\":9,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n", .want = error.DiscontinuousSeq },
    };
    for (cases) |case| {
        try ws.write(try ws.segment(1), case.bytes);
        try testing.expectError(case.want, Journal.open(testing.allocator, io, ws.path, .{}));
    }
}

test "a gap between two segments is refused" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try ws.write(try ws.segment(7), "{\"seq\":7,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try testing.expectError(error.DiscontinuousSeq, Journal.open(testing.allocator, io, ws.path, .{}));
}

test "a write that does not reach the disk publishes nothing and latches" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    _ = try journal.append(io, 1, created(1, "durable"));

    // Take the segment's write access away underneath the journal. A reader
    // must never see a record the disk does not have, so the failed append
    // adds nothing and every later one is refused.
    const active = &journal.log.active.?;
    const length = try active.file.length(io);
    active.file.close(io);
    active.file = try journal.log.dir.openFile(io, &chronicle.segmentName(1), .{});
    active.writer = active.file.writer(io, journal.log.write_buf);
    active.writer.pos = length;

    try testing.expectError(error.WriteFailed, journal.append(io, 2, created(2, "lost")));
    try testing.expect(journal.persistence_failed);
    try testing.expectEqual(@as(u64, 1), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 1), journal.records().records.len);
    try testing.expectError(error.PersistenceFailed, journal.append(io, 3, created(3, "also refused")));
    try testing.expectError(error.PersistenceFailed, journal.compact(io, 0));
}

//========================================================================
// Schema versions.
//========================================================================

test "every fsync policy writes a log that opens with the same records" {
    const io = testing.io;
    // When the bytes reach the platter is not something a test on a running
    // kernel can watch. What this checks is the other half of the promise:
    // that the code path each policy takes -- the seal at a rotation, the one
    // at a close, and neither -- still leaves a whole log behind it.
    for ([_]chronicle.Sync{ .always, .on_segment, .never }) |policy| {
        var ws = try Workspace.init("log");
        defer ws.deinit();
        {
            var journal = try Journal.open(testing.allocator, io, ws.path, .{
                .sync = policy,
                .max_segment_records = 3,
            });
            defer journal.deinit(io);
            for (1..8) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
        }
        var reopened = try Journal.open(testing.allocator, io, ws.path, .{ .verify = .full });
        defer reopened.deinit(io);
        try testing.expectEqual(@as(u64, 7), try reopened.lastSeq(io));
        try testing.expectEqual(@as(usize, 3), reopened.segmentCount());
    }
}

test "a record from a newer schema is refused rather than guessed at" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":9,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try testing.expectError(
        error.NewerSchema,
        Journal.open(testing.allocator, io, ws.path, .{ .schema_version = 2 }),
    );
}

test "a record from an older schema goes through migrate" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // Version 1 called the member `title`; version 2 calls it `name`.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":7,\"title\":\"old\"}}}\n");

    const migrate = struct {
        fn f(from_version: u32, value: std.json.Value) Journal.MigrateError!Event {
            if (from_version != 1) return error.Unmigratable;
            const made = value.object.get("created") orelse return error.Unmigratable;
            return .{ .created = .{
                .id = @intCast(made.object.get("id").?.integer),
                .name = made.object.get("title").?.string,
            } };
        }
    }.f;

    var journal = try Journal.open(testing.allocator, io, ws.path, .{
        .schema_version = 2,
        .migrate = migrate,
    });
    defer journal.deinit(io);

    const record = journal.records().records[0];
    try testing.expectEqual(@as(u32, 1), record.version);
    try testing.expectEqualStrings("old", record.event.created.name);

    // What the hook returned borrows from the record's own arena, so it is
    // still there after the bytes it was read from would have gone.
    _ = try journal.append(io, 2, created(8, "new"));
    try testing.expectEqualStrings("old", journal.records().records[0].event.created.name);
}

test "without a migrate hook an older record lands in the unknown arm" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"retired\":{\"id\":7}}}\n");

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .schema_version = 2 });
    defer journal.deinit(io);

    const record = journal.records().records[0];
    try testing.expectEqual(@as(u32, 1), record.version);
    try testing.expect(record.event == .unknown);
    try testing.expect(record.event.unknown.object.get("retired") != null);
}

test "without a migrate hook and without an unknown arm an older record is refused" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");

    const Strict = union(enum) { removed: struct { id: u32 } };
    try testing.expectError(
        error.OlderSchema,
        chronicle.Journal(Strict).open(testing.allocator, io, ws.path, .{ .schema_version = 2 }),
    );
}

//========================================================================
// Folds, live and from the disk.
//========================================================================

test "a fold built from the disk equals the fold built live" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var live: Registry = .{};
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        try journal.subscribe(io, live.sink());
        _ = try journal.append(io, 1, created(1, "alpha"));
        _ = try journal.append(io, 2, created(2, "beta"));
        _ = try journal.append(io, 3, .{ .renamed = .{ .id = 1, .name = "gamma" } });
        _ = try journal.append(io, 4, .{ .removed = .{ .id = 2 } });
    }

    var replayed: Registry = .{};
    var reopened = try Journal.open(testing.allocator, io, ws.path, .{});
    defer reopened.deinit(io);
    try reopened.subscribe(io, replayed.sink());

    try testing.expectEqual(@as(u32, 4), replayed.events);
    try testing.expectEqual(live, replayed);

    // And a sink keeps seeing records after it has caught up.
    _ = try reopened.append(io, 5, created(3, "delta"));
    try testing.expectEqual(@as(u32, 5), replayed.events);
    try testing.expectEqual(@as(u32, 2), replayed.live);
}

test "waitPast blocks until an append arrives" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);

    const appender = struct {
        fn f(j: *Journal, inner: Io) void {
            _ = j.append(inner, 1, created(1, "awaited")) catch {};
        }
    }.f;

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, appender, .{ &journal, io });

    const arrived = try journal.waitPast(io, 0);
    try testing.expect(arrived.records.len >= 1);
    try testing.expectEqualStrings("awaited", arrived.records[0].event.created.name);
    try group.await(io);
}

test "waitPast is woken by a nudge with no record behind it" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);

    // A nudge wakes whoever is waiting when it happens and is not remembered
    // for a waiter that arrives later, so the nudger repeats until the waiter
    // reports through.
    var woken: std.atomic.Value(bool) = .init(false);
    const nudger = struct {
        fn f(j: *Journal, inner: Io, done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                j.nudge(inner);
                std.atomic.spinLoopHint();
            }
        }
    }.f;

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, nudger, .{ &journal, io, &woken });

    const nothing = try journal.waitPast(io, 0);
    woken.store(true, .release);
    try testing.expectEqual(@as(usize, 0), nothing.records.len);
    try group.await(io);
}

//========================================================================
// Segments, the tail, and reading from the disk.
//========================================================================

/// Options that rotate every few records, so a test can hold several segments
/// without writing megabytes.
fn small(records_per_segment: u64, tail_records: usize) Journal.Options {
    return .{
        .sync = .never,
        .max_segment_records = records_per_segment,
        .tail_records = tail_records,
        .max_segment_bytes = 1 << 30,
    };
}

test "the log rotates into segments named after their first record" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..11) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        try testing.expectEqual(@as(usize, 3), journal.segmentCount());
        try testing.expect(ws.exists(try ws.segment(1)));
        try testing.expect(ws.exists(try ws.segment(5)));
        try testing.expect(ws.exists(try ws.segment(9)));
        try testing.expectEqual(@as(usize, 4), std.mem.count(u8, try ws.read(try ws.segment(1)), "\n"));
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, try ws.read(try ws.segment(9)), "\n"));
    }

    // And a reopen walks them in order.
    var reopened = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 10), try reopened.lastSeq(io));
    const all = reopened.records();
    try testing.expect(all.complete);
    try testing.expectEqual(@as(usize, 10), all.records.len);
    try testing.expectEqual(@as(u64, 1), all.records[0].seq);
    try testing.expectEqual(@as(u64, 10), all.records[9].seq);
}

test "the tail is bounded and a cursor older than it is an incomplete window" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(8, 4));
    defer journal.deinit(io);
    for (1..41) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

    // At most four records in memory for forty on the disk.
    try testing.expect(journal.tail.items.len <= 4);
    const stale = journal.since(1);
    try testing.expect(!stale.complete);
    const fresh = journal.since(39);
    try testing.expect(fresh.complete);
    try testing.expectEqual(@as(usize, 1), fresh.records.len);
    try testing.expectEqual(@as(u64, 40), fresh.records[0].seq);

    // What the window does not reach is on the disk, in order, entire.
    var walk = try journal.replay(io, 0);
    defer walk.deinit(io);
    var seen: u64 = 0;
    while (try walk.next(io)) |record| {
        seen += 1;
        try testing.expectEqual(seen, record.seq);
    }
    try testing.expectEqual(@as(u64, 40), seen);

    // And a replay from a cursor starts at the record straight after it.
    var from_thirty = try journal.replay(io, 30);
    defer from_thirty.deinit(io);
    const first = (try from_thirty.next(io)) orelse return error.TestExpectedRecord;
    try testing.expectEqual(@as(u64, 31), first.seq);
}

test "a reopened journal fills its tail from the newest records only" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(8, 4));
        defer journal.deinit(io);
        for (1..41) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, small(8, 4));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 40), try reopened.lastSeq(io));
    try testing.expect(reopened.tail.items.len <= 4);
    try testing.expect(reopened.tail.items.len >= 1);
    const window = reopened.records();
    try testing.expect(!window.complete);
    try testing.expectEqual(@as(u64, 40), window.records[window.records.len - 1].seq);
    try testing.expectEqual(@as(u64, 41), try reopened.append(io, 41, created(41, "n")));
}

test "subscribe folds a history longer than the tail, streaming from the disk" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var live: Registry = .{};
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(7, 3));
        defer journal.deinit(io);
        try journal.subscribe(io, live.sink());
        for (1..51) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    var replayed: Registry = .{};
    var reopened = try Journal.open(testing.allocator, io, ws.path, small(7, 3));
    defer reopened.deinit(io);
    try reopened.subscribe(io, replayed.sink());

    try testing.expectEqual(@as(u32, 50), replayed.events);
    try testing.expectEqual(@as(u64, 50), replayed.last);
    try testing.expectEqual(live, replayed);

    // No record twice at the seam between the disk and the tail.
    var from_forty: Registry = .{};
    try reopened.subscribeFrom(io, from_forty.sink(), 40);
    try testing.expectEqual(@as(u32, 10), from_forty.events);
}

//========================================================================
// The index.
//========================================================================

test "a missing index is rebuilt and a stale one is not trusted" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 1024));
        defer journal.deinit(io);
        for (1..21) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    // An index a crash never finished, and one from a different segment.
    try ws.tmp.dir.deleteFile(io, try ws.index(1));
    try ws.write(try ws.index(6), "chridx\x01\n" ++ "\xff" ** 8 ++ "\x00" ** 24);

    var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 2));
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 20), try journal.lastSeq(io));

    // A seek into either of those segments still lands on the right record.
    for ([_]u64{ 0, 2, 5, 7, 12, 19 }) |cursor| {
        var walk = try journal.replay(io, cursor);
        defer walk.deinit(io);
        const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
        try testing.expectEqual(cursor + 1, record.seq);
    }

    // The missing one was rebuilt on the way, and it describes its segment.
    try testing.expect(ws.exists(try ws.index(1)));
    try testing.expectEqual(@as(usize, 16 + 5 * 8), (try ws.read(try ws.index(1))).len);
}

test "an index for the wrong segment length is refused and rebuilt" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 1024));
        defer journal.deinit(io);
        for (1..16) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    // Same shape, same count, a length that belongs to nothing: the header is
    // what says which bytes an index was built from.
    const good = try ws.read(try ws.index(1));
    const bad = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad);
    std.mem.writeInt(u64, bad[8..16], 999_999, .little);
    try ws.write(try ws.index(1), bad);

    var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 1));
    defer journal.deinit(io);
    var walk = try journal.replay(io, 2);
    defer walk.deinit(io);
    const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
    try testing.expectEqual(@as(u64, 3), record.seq);
    try testing.expectEqualStrings(good, try ws.read(try ws.index(1)));
}

//========================================================================
// Snapshots, compaction and retention.
//========================================================================

test "a snapshot plus the records after it folds to the whole log" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var whole: Registry = .{};
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        try journal.subscribe(io, whole.sink());
        for (1..11) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        // Halfway through, write the fold out and drop what it already covers.
        var half: Registry = .{};
        try journal.subscribeFrom(io, half.sink(), 0);
        try journal.snapshot(io, std.mem.asBytes(&half));
        try journal.compact(io, try journal.lastSeq(io));

        for (11..16) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    const opened = try Journal.openWithSnapshot(testing.allocator, io, ws.path, small(4, 1024));
    var reopened = opened.journal;
    defer reopened.deinit(io);

    const snapshot = opened.snapshot orelse return error.TestExpectedSnapshot;
    defer testing.allocator.free(snapshot.state);
    try testing.expectEqual(@as(u64, 10), snapshot.seq);
    var restored: Registry = std.mem.bytesToValue(Registry, snapshot.state[0..@sizeOf(Registry)]);
    try reopened.subscribeFrom(io, restored.sink(), snapshot.seq);

    try testing.expectEqual(whole, restored);
    try testing.expectEqual(@as(u64, 15), try reopened.lastSeq(io));
}

test "compact empties the log and the sequence still continues" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
        defer journal.deinit(io);
        for (1..6) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        // A segment's name is the record that will go into it, so a log with
        // nothing in it still knows where it got to.
        try journal.compact(io, 999);
        try testing.expectEqual(@as(usize, 0), journal.records().records.len);
        try testing.expectEqual(@as(usize, 1), journal.segmentCount());
        try testing.expectEqual(@as(u64, 5), try journal.lastSeq(io));
        try testing.expectEqual(@as(u64, 6), try journal.append(io, 6, created(6, "n")));
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 6), try reopened.lastSeq(io));
    try testing.expectEqual(@as(u64, 7), try reopened.append(io, 7, created(7, "n")));
}

test "compact keeps the records after the cut, byte for byte" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..11) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
        const kept = try ws.arena.allocator().dupe(u8, journal.records().records[6].bytes);

        try journal.compact(io, 6);
        try testing.expectEqual(@as(u64, 7), journal.oldestSeq());
        try testing.expectEqual(@as(u64, 10), try journal.lastSeq(io));
        const window = journal.records();
        try testing.expectEqual(@as(usize, 4), window.records.len);
        try testing.expectEqualStrings(kept, window.records[0].bytes);
        try testing.expect(!ws.exists(try ws.segment(1)));
        try testing.expect(ws.exists(try ws.segment(7)));

        // A cursor from before the cut gets what is left and says it is
        // partial.
        try testing.expect(!journal.since(1).complete);
        try testing.expect(journal.since(7).complete);
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(usize, 4), reopened.records().records.len);
    try testing.expectEqual(@as(u64, 11), try reopened.append(io, 11, created(11, "n")));
}

test "compact can cut inside the segment being written to" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer journal.deinit(io);
    for (1..6) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    try testing.expectEqual(@as(usize, 2), journal.segmentCount());

    // The cut falls inside segment 4, which is the one open for appending: it
    // is let go of before the replacement is renamed over it, and picked up
    // again afterwards.
    try journal.compact(io, 4);
    try testing.expectEqual(@as(usize, 1), journal.segmentCount());
    try testing.expectEqual(@as(u64, 5), journal.oldestSeq());
    try testing.expectEqual(@as(usize, 1), journal.records().records.len);
    try testing.expectEqual(@as(u64, 6), try journal.append(io, 6, created(6, "n")));
    try testing.expect(ws.exists(try ws.segment(5)));
    try testing.expect(!ws.exists(try ws.segment(1)));
    try testing.expect(!ws.exists(try ws.sub("00000000000000000005.tmp")));
}

test "the tail gives way by bytes as well as by count" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{
        .sync = .never,
        .tail_records = 1_000,
        .tail_bytes = 512,
    });
    defer journal.deinit(io);

    const long = "a name long enough that a handful of these is already more than the tail may hold";
    for (1..41) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), long));

    try testing.expect(journal.tail_bytes <= 512);
    try testing.expect(journal.tail.items.len < 40);
    try testing.expect(!journal.since(0).complete);
    try testing.expectEqual(@as(u64, 40), journal.records().records[journal.records().records.len - 1].seq);

    // Everything the tail let go of is still on the disk, in order.
    var walk = try journal.replay(io, 0);
    defer walk.deinit(io);
    var seen: u64 = 0;
    while (try walk.next(io)) |record| {
        seen += 1;
        try testing.expectEqual(seen, record.seq);
    }
    try testing.expectEqual(@as(u64, 40), seen);
}

test "truncateAfter drops the records past the cut and hands the numbers back" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer journal.deinit(io);
    for (1..10) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    try testing.expectEqual(@as(usize, 3), journal.segmentCount());

    // A cut past the newest record is not a cut.
    try journal.truncateAfter(io, 99);
    try testing.expectEqual(@as(u64, 9), try journal.lastSeq(io));

    // Inside a segment: the whole segments past it are unlinked, and the one
    // holding the cut is shortened to the record boundary.
    try journal.truncateAfter(io, 5);
    try testing.expectEqual(@as(u64, 5), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 2), journal.segmentCount());
    try testing.expect(!ws.exists(try ws.segment(7)));
    try testing.expectEqual(@as(u64, 5), try journal.verify(io));

    // The number comes back, which is the one thing this call is for.
    try testing.expectEqual(@as(u64, 6), try journal.append(io, 6, created(6, "again")));

    // On a segment boundary nothing is rewritten, only unlinked.
    try journal.truncateAfter(io, 3);
    try testing.expectEqual(@as(u64, 3), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 1), journal.segmentCount());

    // To nothing, which leaves the sequence exactly where it was told to.
    try journal.truncateAfter(io, 0);
    try testing.expectEqual(@as(u64, 0), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 0), journal.records().records.len);
    try testing.expectEqual(@as(u64, 1), try journal.append(io, 1, created(1, "from the top")));

    // And below the oldest record the log still holds there is nothing to
    // truncate to, because the history it would claim has been dropped.
    for (2..8) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    _ = try journal.dropSegmentsBefore(io, 3);
    try testing.expectError(error.SeqTooOld, journal.truncateAfter(io, 1));
}

test "a compaction interrupted after its rename leaves a segment the next open removes" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..9) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    // What the disk holds between the rename and the unlink: the replacement
    // for records 3..4, and the segment it replaces, still there.
    const whole = try ws.read(try ws.segment(1));
    const cut = std.mem.indexOfPos(u8, whole, 0, "{\"seq\":3").?;
    try ws.write(try ws.segment(3), whole[cut..]);

    var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
    defer journal.deinit(io);
    try testing.expect(!ws.exists(try ws.segment(1)));
    try testing.expectEqual(@as(u64, 3), journal.oldestSeq());
    try testing.expectEqual(@as(u64, 8), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 6), journal.records().records.len);
}

test "a temporary file a crash left behind is ignored" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..6) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        try ws.write(try ws.sub("00000000000000000003.tmp"), "half a segment, no newline");
        try ws.write(try ws.sub(chronicle.snapshot_name ++ ".tmp"), "{ not a snapshot");
        try journal.refresh(io);
        try testing.expectEqual(@as(u64, 5), try journal.lastSeq(io));
    }

    const opened = try Journal.openWithSnapshot(testing.allocator, io, ws.path, small(4, 1024));
    var reopened = opened.journal;
    defer reopened.deinit(io);
    try testing.expect(opened.snapshot == null);
    try testing.expectEqual(@as(u64, 5), try reopened.lastSeq(io));
}

test "dropSegmentsBefore unlinks whole segments and never the newest one" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..11) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
        try testing.expectEqual(@as(usize, 3), journal.segmentCount());

        // Only segments whose every record is covered go, so a cut inside one
        // leaves it alone.
        try testing.expectEqual(@as(u64, 1), try journal.dropSegmentsBefore(io, 5));
        try testing.expectEqual(@as(u64, 5), journal.oldestSeq());
        try testing.expect(!ws.exists(try ws.segment(1)));
        try testing.expect(!ws.exists(try ws.index(1)));

        // Asked to drop everything, it keeps the segment being written to.
        try testing.expectEqual(@as(u64, 1), try journal.dropSegmentsBefore(io, 1_000));
        try testing.expectEqual(@as(usize, 1), journal.segmentCount());
        try testing.expectEqual(@as(u64, 10), try journal.lastSeq(io));
        try testing.expectEqual(@as(u64, 11), try journal.append(io, 11, created(11, "n")));
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 9), reopened.oldestSeq());
    try testing.expectEqual(@as(u64, 11), try reopened.lastSeq(io));
}

//========================================================================
// More than one process.
//========================================================================

test "a second writer is refused while the first holds the lock" {
    const io = testing.io;
    const helper = testing.environ.getAlloc(testing.allocator, "CHRONICLE_LOCK_HELPER") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(helper);

    var ws = try Workspace.init("log");
    defer ws.deinit();
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        _ = try journal.append(io, 1, created(1, "mine"));
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ helper, ws.path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    // The helper says when the lock is its.
    var buffer: [64]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &buffer);
    const line = try out.interface.takeDelimiterExclusive('\n');
    try testing.expectEqualStrings("locked", line);

    // A second writer is told so, rather than interleaving half-records.
    try testing.expectError(error.Locked, Journal.open(testing.allocator, io, ws.path, .{}));

    // A reader is not: it takes no lock and writes nothing.
    var reader = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read });
    defer reader.deinit(io);
    try testing.expectEqual(@as(u64, 1), try reader.lastSeq(io));
    try testing.expectError(error.ReadOnly, reader.append(io, 2, created(2, "not mine")));
    try testing.expectError(error.ReadOnly, reader.compact(io, 0));
    try testing.expectError(error.ReadOnly, reader.snapshot(io, "state"));

    // And the lock comes back when the process holding it goes.
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
    var second = try Journal.open(testing.allocator, io, ws.path, .{});
    defer second.deinit(io);
    try testing.expectEqual(@as(u64, 2), try second.append(io, 2, created(2, "mine again")));
}

test "a reader tails a writer by refreshing past its cursor" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var writer = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer writer.deinit(io);
    for (1..4) |i| _ = try writer.append(io, @intCast(i), created(@intCast(i), "n"));

    var reader = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read, .tail_records = 1024 });
    defer reader.deinit(io);
    try testing.expectEqual(@as(u64, 3), try reader.lastSeq(io));

    // The writer rotates past the reader; refreshing is what picks that up.
    for (4..10) |i| _ = try writer.append(io, @intCast(i), created(@intCast(i), "n"));
    try reader.refresh(io);
    try testing.expectEqual(@as(u64, 9), try reader.lastSeq(io));

    var walk = try reader.replay(io, 3);
    defer walk.deinit(io);
    var seen: u64 = 3;
    while (try walk.next(io)) |record| {
        seen += 1;
        try testing.expectEqual(seen, record.seq);
    }
    try testing.expectEqual(@as(u64, 9), seen);
}

test "a reader beside a writer mid-record sees the records, not the fragment" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // What a reader finds if it looks between a writer's `write` and its
    // newline: a complete log and a fragment. The fragment is not damage and
    // the reader must not shorten the file to be rid of it.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n" ++
        "{\"seq\":2,\"at\":2,\"v\":1,\"ev\":{\"remo");
    const before = try ws.read(try ws.segment(1));

    var reader = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read });
    defer reader.deinit(io);
    try testing.expectEqual(@as(u64, 1), try reader.lastSeq(io));
    try testing.expectEqual(@as(usize, 0), reader.dropped_bytes);
    try testing.expectEqualStrings(before, try ws.read(try ws.segment(1)));
    try testing.expect(!ws.exists(try ws.sub(chronicle.lock_name)));
}

//========================================================================
// Checksums.
//========================================================================

test "a flipped byte is caught by the checksum, and a parse would not have been" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        _ = try journal.append(io, 1, created(1, "one"));
        _ = try journal.append(io, 2, created(2, "two"));
    }

    // A byte inside the payload, not the envelope. The line still parses as
    // the object this format requires, its `ev` still parses as an `Event`,
    // and the sequence still runs without a gap: the checksum is the only
    // thing left that can say the bytes are not the ones that were written.
    const bytes = try ws.read(try ws.segment(1));
    bytes[std.mem.indexOf(u8, bytes, "two").?] = 'x';
    try ws.write(try ws.segment(1), bytes);

    try testing.expectError(
        error.ChecksumMismatch,
        Journal.open(testing.allocator, io, ws.path, .{}),
    );
}

test "a flipped byte in a sealed segment is what the full open is for" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 2));
        defer journal.deinit(io);
        for (1..10) |i| {
            const name: [2]u8 = .{ 'r', '0' + @as(u8, @intCast(i)) };
            _ = try journal.append(io, @intCast(i), created(@intCast(i), &name));
        }
    }

    // The second record of the oldest segment: not its last line, so nothing
    // a quick open reads goes near it.
    const bytes = try ws.read(try ws.segment(1));
    bytes[std.mem.indexOf(u8, bytes, "r2").? + 1] = 'x';
    try ws.write(try ws.segment(1), bytes);

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 2));
        defer journal.deinit(io);
        try testing.expectEqual(@as(u64, 9), try journal.lastSeq(io));

        // Reading it is what finds it, and `verify` is reading all of it.
        try testing.expectError(error.ChecksumMismatch, journal.verify(io));
    }

    var full = small(3, 2);
    full.verify = .full;
    try testing.expectError(
        error.ChecksumMismatch,
        Journal.open(testing.allocator, io, ws.path, full),
    );
}

test "a checksum that is not the last member of its line is not a checksum" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // A `c` this package cannot have written: there is no prefix it could be
    // the checksum of, so the line is refused rather than read unverified.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"c\":0,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try testing.expectError(
        error.CorruptRecord,
        Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail }),
    );
}

test "a record written before checksums existed is read as it always was" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // The envelope 0.2.0 wrote, with no `c` member. There is nothing to
    // verify, and having nothing to verify is not a failure to verify.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":1,\"name\":\"old\"}}}\n");

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .verify = .full });
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 1), try journal.lastSeq(io));
    try testing.expectEqualStrings("old", journal.records().records[0].event.created.name);

    // A record appended beside it carries one, so a journal gains checksums
    // as it is written to rather than needing a conversion.
    _ = try journal.append(io, 2, created(2, "new"));
    const bytes = try ws.read(try ws.segment(1));
    try testing.expect(std.mem.count(u8, bytes, ",\"c\":") == 1);
    try testing.expectEqual(@as(u64, 2), try journal.verify(io));
}

//========================================================================
// Size.
//========================================================================

test "two hundred thousand records open within a bounded time and memory" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    const count = 200_000;
    {
        // No fsync here: this is building a fixture, not measuring durability.
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
        defer journal.deinit(io);
        for (0..count) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "a name of some length"));
        try testing.expect(journal.segmentCount() > 1);
    }

    const started = Io.Clock.awake.now(io);
    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();

    try testing.expectEqual(@as(u64, count), try journal.lastSeq(io));

    // Loose on purpose: the point is that opening a long log costs the newest
    // segment and the tail, not the log, and that neither grows with it.
    try testing.expect(elapsed_ms < 30_000);
    try testing.expect(journal.tail.items.len <= journal.options.tail_records);
    var held: usize = journal.scratch.queryCapacity();
    for (journal.tail_arenas.items) |*arena| held += arena.queryCapacity();
    try testing.expect(held < 4 * 1024 * 1024);

    // And a fold over the whole of it still holds one record at a time.
    var counted: Registry = .{};
    try journal.subscribe(io, counted.sink());
    try testing.expectEqual(@as(u64, count), counted.last);
    try testing.expectEqual(@as(u32, count), counted.events);
}

//========================================================================
// Fuzzing.
//
// A journal file is written by the program that owns it, so these are not
// about hostile input; they are about the crash cases, which produce file
// contents nobody chose. Under `zig build test` each of these runs its
// corpus and nothing else, which is fast; `zig build test --fuzz` is what
// explores from there.
//========================================================================

/// One corpus entry for a test whose first call is `Smith.slice`: a
/// little-endian byte count and then the bytes, which is how that call reads
/// one byte string out of the fuzzer's input.
fn seeded(comptime body: []const u8) []const u8 {
    comptime {
        var entry: [4 + body.len]u8 = undefined;
        std.mem.writeInt(u32, entry[0..4], body.len, .little);
        @memcpy(entry[4..], body);
        const frozen = entry;
        return &frozen;
    }
}

const a_record = "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":1,\"name\":\"x\"}}}\n";
/// The same record as this version writes it: the checksum of everything
/// before `,"c":`, which is `a_record` without its closing brace.
const a_checked_record =
    "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":1,\"name\":\"x\"}},\"c\":825182072}\n";

/// Inputs worth starting from: the empty file, a whole record, a record cut
/// off mid-write, and the shapes that have to be refused by name.
const open_corpus = [_][]const u8{
    seeded(""),
    seeded("\n"),
    seeded("\n\n"),
    seeded("{"),
    seeded(a_record),
    seeded(a_record ++ a_record),
    seeded(a_record ++ "{\"seq\":2,\"at\":2,\"v\":1,\"ev\":{\"crea"),
    seeded(a_checked_record),
    seeded(a_checked_record ++ a_checked_record),
    seeded(a_checked_record ++ "{\"seq\":2,\"at\":2,\"v\":1,\"ev\":{\"created\":{\"id\":2,\"name\":\"x\"}},\"c\":0}\n"),
    seeded("{\"seq\":1,\"at\":1,\"v\":1,\"ev\":null,\"c\":4294967296}\n"),
    seeded("{\"seq\":1,\"c\":0,\"at\":1,\"v\":1,\"ev\":null}\n"),
    seeded("{\"seq\":0,\"at\":0,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n"),
    seeded("{\"seq\":9223372036854775807,\"at\":0,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n"),
    seeded("{\"seq\":1,\"at\":1,\"v\":4294967296,\"ev\":null}\n"),
    seeded("{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":-1,\"name\":null}}}\n"),
    seeded("[[[[[[[[[[[[[[[[[[[[\n"),
    seeded("\x00\xff\xfe\n"),
};

test "fuzz: open of arbitrary segment contents, and the repair it promises" {
    try testing.fuzz({}, fuzzOpen, .{ .corpus = &open_corpus });
}

fn fuzzOpen(_: void, smith: *testing.Smith) anyerror!void {
    const io = testing.io;
    // Bounded so that a generated run of `[` cannot recurse the JSON parser
    // deeper than a stack holds. A journal record is not adversarial input.
    var buffer: [1024]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];

    var ws = try Workspace.init("log");
    defer ws.deinit();
    const name = try ws.segment(1);
    try ws.write(name, bytes);

    // `.fail` is the mode that promises to leave the file as it found it.
    if (Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail })) |untouched| {
        var journal = untouched;
        defer journal.deinit(io);
        try testing.expectEqual(@as(usize, 0), journal.dropped_bytes);
    } else |_| {}
    try testing.expectEqualStrings(bytes, try ws.read(name));

    // `.drop` promises a log the next append can extend. Whatever it made of
    // these bytes, appending to it and opening again has to agree.
    var held: u64 = 0;
    {
        var journal = Journal.open(testing.allocator, io, ws.path, .{}) catch |err| {
            try testing.expect(err != error.TruncatedRecord);
            return;
        };
        defer journal.deinit(io);
        _ = journal.append(io, 2, created(2, "after the repair")) catch |err| {
            // The one refusal a well-formed journal can still give: the last
            // sequence number a JSON integer can hold is already taken.
            try testing.expectEqual(error.SequenceExhausted, err);
            return;
        };
        held = try journal.lastSeq(io);
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail });
    defer reopened.deinit(io);
    try testing.expectEqual(held, try reopened.lastSeq(io));
    try testing.expectEqual(@as(usize, 0), reopened.dropped_bytes);
}

const index_corpus = [_][]const u8{
    seeded(""),
    seeded("chridx\x01\n"),
    seeded("chridx\x01\n" ++ "\x00" ** 8),
    seeded("chridx\x01\n" ++ "\x00" ** 16),
    seeded("chridx\x01\n" ++ "\xff" ** 16),
    seeded("not an index at all"),
    seeded("chridx\x01\n" ++ "\x3f\x00\x00\x00\x00\x00\x00\x00" ++ "\x00" ** 8),
};

test "fuzz: an arbitrary index file is a cache, never an answer" {
    try testing.fuzz({}, fuzzIndex, .{ .corpus = &index_corpus });
}

fn fuzzIndex(_: void, smith: *testing.Smith) anyerror!void {
    const io = testing.io;
    var buffer: [512]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];

    var ws = try Workspace.init("log");
    defer ws.deinit();
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
        defer journal.deinit(io);
        for (1..10) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }
    try ws.write(try ws.index(1), bytes);
    try ws.write(try ws.index(4), bytes);

    // Whatever the sidecar says, the records are what the segments hold.
    var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1));
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 9), try journal.lastSeq(io));
    for ([_]u64{ 0, 1, 4, 5, 8 }) |cursor| {
        var walk = try journal.replay(io, cursor);
        defer walk.deinit(io);
        var seen = cursor;
        while (try walk.next(io)) |record| {
            seen += 1;
            try testing.expectEqual(seen, record.seq);
        }
        try testing.expectEqual(@as(u64, 9), seen);
    }
}

const snapshot_corpus = [_][]const u8{
    seeded(""),
    seeded("{}"),
    seeded("{\"seq\":1,\"state\":\"\"}"),
    seeded("{\"seq\":1,\"state\":\"aGk=\"}"),
    seeded("{\"seq\":1,\"state\":\"not base64!\"}"),
    seeded("{\"seq\":-1,\"state\":\"aGk=\"}"),
    seeded("{\"state\":\"aGk=\"}"),
    seeded("[1,2,3]"),
};

test "fuzz: openWithSnapshot over an arbitrary snapshot file" {
    try testing.fuzz({}, fuzzSnapshot, .{ .corpus = &snapshot_corpus });
}

fn fuzzSnapshot(_: void, smith: *testing.Smith) anyerror!void {
    const io = testing.io;
    var buffer: [1024]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];

    var ws = try Workspace.init("log");
    defer ws.deinit();
    try ws.write(try ws.segment(1), a_record);
    try ws.write(try ws.sub(chronicle.snapshot_name), bytes);

    // A snapshot is an optimisation. A bad one must be an error the caller can
    // name -- never a journal that opens with a wrong starting point.
    const opened = Journal.openWithSnapshot(testing.allocator, io, ws.path, .{}) catch |err| {
        try testing.expectEqual(error.CorruptSnapshot, err);
        return;
    };
    var journal = opened.journal;
    defer journal.deinit(io);
    try testing.expectEqual(@as(usize, 1), journal.records().records.len);
    if (opened.snapshot) |snapshot| {
        defer testing.allocator.free(snapshot.state);
        // Whatever sequence number the file claimed, a cursor is clamped to
        // what the journal holds rather than indexing past it.
        try testing.expect(journal.since(snapshot.seq).records.len <= journal.records().records.len);
    }
}
