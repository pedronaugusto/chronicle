//! The suite. Every test opens a real journal on a real file through
//! `std.testing.io`, because what this package promises is about files.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zjournal = @import("zjournal.zig");

/// The events of a tiny registry: enough shape to fold, and an `unknown` arm
/// so a record from an older schema has somewhere to land.
const Event = union(enum) {
    created: struct { id: u32, name: []const u8 },
    renamed: struct { id: u32, name: []const u8 },
    removed: struct { id: u32 },
    unknown: std.json.Value,
};

const Journal = zjournal.Journal(Event);

/// A fold: the state the log adds up to. Two folds of the same records are
/// equal whether the records came off the disk or arrived live, which is what
/// several tests below check.
const Registry = struct {
    live: u32 = 0,
    events: u32 = 0,
    unknown: u32 = 0,
    names: u64 = 0,

    fn sink(self: *Registry) Journal.Sink {
        return .{ .ctx = self, .f = apply };
    }

    fn apply(ctx: *anyopaque, record: Journal.Record) void {
        const self: *Registry = @ptrCast(@alignCast(ctx));
        self.events += 1;
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

/// A temporary directory plus an absolute path inside it, torn down together.
const Workspace = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    path: []const u8,

    fn init(name: []const u8) !Workspace {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
        const path = try std.fs.path.join(arena.allocator(), &.{ root, name });
        return .{ .tmp = tmp, .arena = arena, .path = path };
    }

    fn deinit(self: *Workspace) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn read(self: *Workspace, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, self.arena.allocator(), .unlimited);
    }

    fn write(self: *Workspace, sub_path: []const u8, data: []const u8) !void {
        return self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }
};

test "an append returns the sequence number and puts one line on the disk" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);

    try testing.expectEqual(@as(u64, 1), try journal.append(io, 1_000, created(1, "one")));
    try testing.expectEqual(@as(u64, 2), try journal.append(io, 2_000, created(2, "two")));

    const on_disk = try ws.read("log.jsonl");
    try testing.expectEqualStrings(
        \\{"seq":1,"at":1000,"v":1,"ev":{"created":{"id":1,"name":"one"}}}
        \\{"seq":2,"at":2000,"v":1,"ev":{"created":{"id":2,"name":"two"}}}
        \\
    , on_disk);

    // The record in memory is the line on the disk, parsed.
    const all = journal.records();
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("two", all[1].event.created.name);
    try testing.expectEqual(@as(i64, 2_000), all[1].at);

    // A cursor is where a reader got to, so `since` is the rest of the log --
    // and a cursor past the end is a reader ahead of this process, not an
    // error.
    try testing.expectEqual(@as(usize, 1), journal.since(1).len);
    try testing.expectEqual(@as(usize, 0), journal.since(2).len);
    try testing.expectEqual(@as(usize, 0), journal.since(99).len);
}

test "a reopened journal continues the sequence and appends after the last line" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
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
    try testing.expectEqual(@as(usize, 2), second.records().len);
    try testing.expectEqualStrings("before", second.records()[0].event.created.name);

    // Two records sharing a number would make a cursor ambiguous, so the seq
    // continues rather than starting again -- and the line lands after the
    // history rather than over it.
    try testing.expectEqual(@as(u64, 3), try second.append(io, 3, created(3, "after")));
    const on_disk = try ws.read("log.jsonl");
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, on_disk, "\n"));
    try testing.expect(std.mem.indexOf(u8, on_disk, "\"seq\":3") != null);
}

test "a final line the writer did not finish is dropped and the file repaired" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    const whole =
        \\{"seq":1,"at":1,"v":1,"ev":{"created":{"id":1,"name":"kept"}}}
        \\
    ;
    const partial = "{\"seq\":2,\"at\":2,\"v\":1,\"ev\":{\"crea";
    try ws.write("log.jsonl", whole ++ partial);

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);

    try testing.expectEqual(@as(usize, partial.len), journal.dropped_bytes);
    try testing.expectEqual(@as(usize, 1), journal.records().len);
    try testing.expectEqual(@as(u64, 1), try journal.lastSeq(io));

    // Repaired means the next append is well formed, not merely that this
    // process ignored the tail.
    _ = try journal.append(io, 3, created(2, "next"));
    const on_disk = try ws.read("log.jsonl");
    try testing.expect(std.mem.indexOf(u8, on_disk, "crea\"") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, on_disk, "\n"));

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{});
    defer reopened.deinit(io);
    try testing.expectEqual(@as(usize, 2), reopened.records().len);
    try testing.expectEqual(@as(usize, 0), reopened.dropped_bytes);
}

test "on_truncated .fail refuses the journal and leaves the file as found" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    const bytes = "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n{\"seq\":2";
    try ws.write("log.jsonl", bytes);
    try testing.expectError(
        error.TruncatedRecord,
        Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail }),
    );
    try testing.expectEqualStrings(bytes, try ws.read("log.jsonl"));
}

test "a corrupt or discontinuous line is refused" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    const cases = [_]struct { bytes: []const u8, want: anyerror }{
        .{ .bytes = "not json\n", .want = error.CorruptRecord },
        .{ .bytes = "{\"seq\":1,\"at\":1,\"v\":1}\n", .want = error.CorruptRecord },
        .{ .bytes = "{\"seq\":2,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n" ++
            "{\"seq\":4,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n", .want = error.DiscontinuousSeq },
    };
    for (cases) |case| {
        try ws.write("log.jsonl", case.bytes);
        try testing.expectError(case.want, Journal.open(testing.allocator, io, ws.path, .{}));
    }
}

test "a record from a newer schema is refused rather than guessed at" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();
    try ws.write("log.jsonl", "{\"seq\":1,\"at\":1,\"v\":9,\"ev\":{\"removed\":{\"id\":1}}}\n");
    try testing.expectError(
        error.NewerSchema,
        Journal.open(testing.allocator, io, ws.path, .{ .schema_version = 2 }),
    );
}

test "a record from an older schema goes through migrate" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    // Version 1 called the member `title`; version 2 calls it `name`.
    try ws.write("log.jsonl", "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"created\":{\"id\":7,\"title\":\"old\"}}}\n");

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

    const record = journal.records()[0];
    try testing.expectEqual(@as(u32, 1), record.version);
    try testing.expectEqualStrings("old", record.event.created.name);

    // What the hook returned borrows from the journal's arena, so it is still
    // there after the bytes it was read from would have gone.
    _ = try journal.append(io, 2, created(8, "new"));
    try testing.expectEqualStrings("old", journal.records()[0].event.created.name);
}

test "without a migrate hook an older record lands in the unknown arm" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();
    try ws.write("log.jsonl", "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"retired\":{\"id\":7}}}\n");

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .schema_version = 2 });
    defer journal.deinit(io);

    const record = journal.records()[0];
    try testing.expectEqual(@as(u32, 1), record.version);
    try testing.expect(record.event == .unknown);
    try testing.expect(record.event.unknown.object.get("retired") != null);
}

test "without a migrate hook and without an unknown arm an older record is refused" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();
    try ws.write("log.jsonl", "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n");

    const Strict = union(enum) { removed: struct { id: u32 } };
    try testing.expectError(
        error.OlderSchema,
        zjournal.Journal(Strict).open(testing.allocator, io, ws.path, .{ .schema_version = 2 }),
    );
}

test "a fold built from the disk equals the fold built live" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
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
    var ws = try Workspace.init("log.jsonl");
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
    try testing.expect(arrived.len >= 1);
    try testing.expectEqualStrings("awaited", arrived[0].event.created.name);
    try group.await(io);
}

test "waitPast is woken by a nudge with no record behind it" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
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
    try testing.expectEqual(@as(usize, 0), nothing.len);
    try group.await(io);
}

test "a write that does not reach the disk publishes nothing and latches" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    _ = try journal.append(io, 1, created(1, "durable"));

    // Take the file's write access away underneath the journal. A reader must
    // never see a record the disk does not have, so the failed append adds
    // nothing and every later one is refused.
    const length = try journal.file.length(io);
    journal.file.close(io);
    journal.file = try Io.Dir.cwd().openFile(io, ws.path, .{});
    journal.writer = journal.file.writer(io, journal.write_buf);
    journal.writer.pos = length;

    try testing.expectError(error.WriteFailed, journal.append(io, 2, created(2, "lost")));
    try testing.expect(journal.persistence_failed);
    try testing.expectEqual(@as(u64, 1), try journal.lastSeq(io));
    try testing.expectEqual(@as(usize, 1), journal.records().len);
    try testing.expectError(error.PersistenceFailed, journal.append(io, 3, created(3, "also refused")));
    try testing.expectError(error.PersistenceFailed, journal.compact(io, 0));
}

test "a snapshot plus the records after it folds to the whole log" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    var whole: Registry = .{};
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        try journal.subscribe(io, whole.sink());
        for (0..10) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        // Halfway through, write the fold out and drop what it already covers.
        var half: Registry = .{};
        try journal.subscribeFrom(io, half.sink(), 0);
        try journal.snapshot(io, std.mem.asBytes(&half));
        try journal.compact(io, try journal.lastSeq(io));

        for (10..15) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    const opened = try Journal.openWithSnapshot(testing.allocator, io, ws.path, .{});
    var reopened = opened.journal;
    defer reopened.deinit(io);

    const snapshot = opened.snapshot orelse return error.TestExpectedSnapshot;
    try testing.expectEqual(@as(u64, 10), snapshot.seq);
    var restored: Registry = std.mem.bytesToValue(Registry, snapshot.state[0..@sizeOf(Registry)]);
    try reopened.subscribeFrom(io, restored.sink(), snapshot.seq);

    try testing.expectEqual(whole, restored);
    try testing.expectEqual(@as(u64, 15), try reopened.lastSeq(io));
}

test "compact keeps the newest record so the sequence survives a reopen" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        for (0..5) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        // Even asked to keep nothing, compaction leaves the last record: a
        // journal compacted to empty would start counting from one again.
        try journal.compact(io, 999);
        try testing.expectEqual(@as(usize, 1), journal.records().len);
        try testing.expectEqual(@as(u64, 5), journal.records()[0].seq);
        try testing.expectEqual(@as(u64, 6), try journal.append(io, 6, created(6, "n")));
        try testing.expectEqual(@as(usize, 0), journal.since(6).len);
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{});
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 6), try reopened.lastSeq(io));
    try testing.expectEqual(@as(u64, 7), try reopened.append(io, 7, created(7, "n")));
}

test "a compact interrupted before its rename leaves the journal whole" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    for (0..5) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    const before = try ws.read("log.jsonl");

    // The replacement is a whole file before it is a journal: until the
    // rename, the journal on the disk is the old one, entire.
    journal.fail_compact_before_rename = true;
    try testing.expectError(error.InterruptedForTest, journal.compact(io, 3));
    journal.fail_compact_before_rename = false;

    try testing.expectEqualStrings(before, try ws.read("log.jsonl"));
    try testing.expectEqual(@as(usize, 5), journal.records().len);
    try testing.expectError(error.FileNotFound, ws.read("log.jsonl" ++ zjournal.compact_suffix));

    // And the real thing still works afterwards.
    try journal.compact(io, 3);
    try testing.expectEqual(@as(usize, 2), journal.records().len);
    try testing.expectEqual(@as(u64, 4), journal.records()[0].seq);
    try testing.expectError(error.FileNotFound, ws.read("log.jsonl" ++ zjournal.compact_suffix));

    // A cursor from before the compaction gets what is left, not a crash.
    try testing.expectEqual(@as(usize, 2), journal.since(1).len);
    try testing.expectEqual(@as(usize, 1), journal.since(4).len);
}

test "twenty thousand records open within a bounded time and memory" {
    const io = testing.io;
    var ws = try Workspace.init("log.jsonl");
    defer ws.deinit();

    const count = 20_000;
    {
        // No fsync here: this is building a fixture, not measuring durability.
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .fsync = false });
        defer journal.deinit(io);
        for (0..count) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "a name of some length"));
    }

    const started = Io.Clock.awake.now(io);
    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();

    try testing.expectEqual(@as(usize, count), journal.records().len);
    try testing.expectEqual(@as(u64, count), try journal.lastSeq(io));

    // Loose on purpose: the point is that reading back the log is linear and
    // proportionate, not that this machine hits a number.
    const file_bytes = (try ws.read("log.jsonl")).len;
    try testing.expect(elapsed_ms < 20_000);
    try testing.expect(journal.arena.queryCapacity() < 32 * file_bytes);
    try testing.expect(journal.scratch.queryCapacity() < 64 * 1024);
}
