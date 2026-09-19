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

/// This process's identifier — the one thing a worker forked from the test
/// runner does not share with the runner or with its siblings.
fn processId() u64 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.posix.system.getpid());
}

/// Counts the workspaces this process has made, so that two of them in the
/// same test binary cannot share a name either.
var workspaces: std.atomic.Value(u64) = .init(0);

/// A directory name no other process can choose.
///
/// `std.testing.tmpDir` names its directory from the test runner's random
/// stream. A fuzzing run forks several workers, each inheriting that stream at
/// the point it was forked, so every worker asks for the same directory in the
/// same order: one of them removes the directory another is working in, and
/// the failure that comes back is whatever the loser happened to be doing —
/// `error.FileNotFound`, `error.Locked`, `error.BadPathName`. The process id
/// and a counter are unique without depending on randomness at all; the
/// trailing bytes come from `randomSecure`, which reads fresh entropy rather
/// than a stored state a fork could have copied, so a directory a crashed run
/// left behind is not picked up either.
fn workspaceName(buffer: *[64]u8) []const u8 {
    var fresh: [8]u8 = undefined;
    testing.io.randomSecure(&fresh) catch testing.io.random(&fresh);
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/chronicle-{d}-{d}-{x}", .{
        processId(),
        workspaces.fetchAdd(1, .monotonic),
        std.mem.readInt(u64, &fresh, .little),
    }) catch unreachable;
}

/// A temporary directory plus the absolute path of a journal inside it, torn
/// down together. `sub` names a file relative to the temporary directory, so a
/// test can write the file shapes a crash produces and open them.
const Workspace = struct {
    root: Io.Dir,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    path: []const u8,
    /// Where `root` is, relative to the current directory, for `deleteTree`.
    root_path: []const u8,

    fn init(name: []const u8) !Workspace {
        const io = testing.io;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();

        var buffer: [64]u8 = undefined;
        const root_path = try arena.allocator().dupe(u8, workspaceName(&buffer));
        const cwd: Io.Dir = .cwd();
        try cwd.createDirPath(io, root_path);
        errdefer cwd.deleteTree(io, root_path) catch {};
        const root = try cwd.openDir(io, root_path, .{ .iterate = true });
        errdefer root.close(io);

        const absolute = try root.realPathFileAlloc(io, ".", arena.allocator());
        const path = try std.fs.path.join(arena.allocator(), &.{ absolute, name });
        return .{ .root = root, .arena = arena, .name = name, .path = path, .root_path = root_path };
    }

    fn deinit(self: *Workspace) void {
        const io = testing.io;
        self.root.close(io);
        Io.Dir.cwd().deleteTree(io, self.root_path) catch {};
        self.arena.deinit();
    }

    /// `<journal>/<file>`, relative to the temporary directory.
    fn sub(self: *Workspace, file: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.name, file });
    }

    /// An absolute path beside the journal, for a second directory a test
    /// needs — somewhere to copy into, and never inside the journal.
    fn beside(self: *Workspace, other: []const u8) ![]const u8 {
        const root = std.fs.path.dirname(self.path).?;
        return std.fs.path.join(self.arena.allocator(), &.{ root, other });
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
        return self.root.readFileAlloc(testing.io, sub_path, self.arena.allocator(), .unlimited);
    }

    fn write(self: *Workspace, sub_path: []const u8, data: []const u8) !void {
        self.root.createDirPath(testing.io, self.name) catch {};
        return self.root.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn exists(self: *Workspace, sub_path: []const u8) bool {
        self.root.access(testing.io, sub_path, .{}) catch return false;
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
// Batches.
//========================================================================

test "appendAll writes every entry and numbers them in order" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var folded: Registry = .{};
    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    try journal.subscribe(io, folded.sink());

    // An empty batch writes nothing and says where the log got to.
    try testing.expectEqual(@as(u64, 0), try journal.appendAll(io, &.{}));

    _ = try journal.append(io, 1, created(1, "alone"));
    const batch = [_]Journal.Entry{
        .{ .at = 20, .event = created(2, "two") },
        .{ .at = 30, .event = .{ .renamed = .{ .id = 2, .name = "three" } } },
        .{ .at = 40, .event = .{ .removed = .{ .id = 2 } } },
    };
    // The returned number is the last of the batch, so the records it wrote
    // are the three sequence numbers ending there.
    try testing.expectEqual(@as(u64, 4), try journal.appendAll(io, &batch));
    try testing.expectEqual(@as(u64, 4), try journal.lastSeq(io));

    // Every record went to the sinks, in order, as if appended one at a time.
    try testing.expectEqual(@as(u32, 4), folded.events);
    try testing.expectEqual(@as(u64, 4), folded.last);
    try testing.expectEqual(@as(u32, 1), folded.live);

    // And the lines are on the disk with their own timestamps and checksums.
    const on_disk = try ws.read(try ws.segment(1));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, on_disk, "\n"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, on_disk, ",\"c\":"));
    try testing.expect(std.mem.indexOf(u8, on_disk, "\"seq\":3,\"at\":30") != null);
    try testing.expectEqual(@as(u64, 4), try journal.verify(io));

    // A batch crossing a rotation is still one batch.
    var rolled = try Workspace.init("rolled");
    defer rolled.deinit();
    var rolling = try Journal.open(testing.allocator, io, rolled.path, small(2, 1024));
    defer rolling.deinit(io);
    var many: [7]Journal.Entry = undefined;
    for (&many, 0..) |*entry, i| entry.* = .{ .at = @intCast(i), .event = created(@intCast(i), "n") };
    try testing.expectEqual(@as(u64, 7), try rolling.appendAll(io, &many));
    try testing.expectEqual(@as(usize, 4), rolling.segmentCount());
    try testing.expectEqual(@as(u64, 7), try rolling.verify(io));
}

test "a batch cut off at any byte leaves a prefix of it, and the log goes on" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // The bytes one batch puts on the disk. Every one of them is a moment a
    // crash could have happened in.
    const batch = [_]Journal.Entry{
        .{ .at = 10, .event = created(1, "one") },
        .{ .at = 20, .event = created(2, "two") },
        .{ .at = 30, .event = created(3, "three") },
        .{ .at = 40, .event = created(4, "four") },
    };
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);
        try testing.expectEqual(@as(u64, 4), try journal.appendAll(io, &batch));
    }
    const whole = try ws.read(try ws.segment(1));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, whole, "\n"));

    const name = try ws.segment(1);
    var cut: usize = 0;
    while (cut <= whole.len) : (cut += 1) {
        const stopped = whole[0..cut];
        // A prefix of the batch is whole records up to the last newline; the
        // bytes after it are the line the writer was in the middle of.
        const complete = std.mem.lastIndexOfScalar(u8, stopped, '\n');
        const kept = if (complete) |at| stopped[0 .. at + 1] else stopped[0..0];
        const records = std.mem.count(u8, kept, "\n");

        try ws.write(name, stopped);
        var journal = try Journal.open(testing.allocator, io, ws.path, .{});
        defer journal.deinit(io);

        // What survived is a prefix of the batch, byte for byte -- not a
        // rewritten one, and never a record the batch did not write.
        try testing.expectEqualStrings(kept, try ws.read(name));
        try testing.expectEqual(@as(usize, stopped.len - kept.len), journal.dropped_bytes);
        try testing.expectEqual(@as(u64, records), try journal.lastSeq(io));
        try testing.expectEqual(@as(u64, records), try journal.verify(io));

        // And the log the crash left is one that continues: the next record
        // takes the number after the last one that survived.
        try testing.expectEqual(
            @as(u64, records + 1),
            try journal.append(io, 99, created(9, "after the crash")),
        );
    }
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

test "the durable write is the one this platform needs" {
    // `fsync` on Darwin returns when the bytes are in the drive's write
    // cache, so a promise about a power cut there has to be `F_FULLFSYNC`.
    // This is the assertion behind README.md's durability table: if the
    // platform row changes, this fails rather than the document going quietly
    // out of date.
    const expected: chronicle.Flush = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .full_fsync,
        .windows => .flush_buffers,
        else => .fsync,
    };
    try testing.expectEqual(expected, chronicle.flush);
}

test "a reserved segment is written into rather than extended, and reserves nothing when closed" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    const reserve = 64 * 1024;
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{
            .sync = .always,
            .preallocate_bytes = reserve,
        });
        defer journal.deinit(io);
        for (1..51) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

        // The file is already longer than its records: the space after them
        // is zeros, and the next append goes into it.
        const held = (try ws.read(try ws.segment(1))).len;
        try testing.expect(held >= reserve);
        try testing.expectEqual(@as(u64, 50), try journal.lastSeq(io));
    }

    // A close cuts the reservation back, so a segment on the disk is its
    // records and nothing else.
    const closed = try ws.read(try ws.segment(1));
    try testing.expect(closed.len < reserve);
    try testing.expectEqual(@as(u8, '\n'), closed[closed.len - 1]);

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{ .preallocate_bytes = reserve });
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 50), try reopened.lastSeq(io));
    try testing.expectEqual(@as(usize, 0), reopened.dropped_bytes);
}

test "space a writer reserved and never filled is not a record it did not finish" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // What a crash leaves behind with a reservation outstanding: whole
    // records, then the zeros nothing was written into.
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
        defer journal.deinit(io);
        for (1..4) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }
    const records = try ws.read(try ws.segment(1));
    const crashed = try testing.allocator.alloc(u8, records.len + 4096);
    defer testing.allocator.free(crashed);
    @memcpy(crashed[0..records.len], records);
    @memset(crashed[records.len..], 0);
    try ws.write(try ws.segment(1), crashed);

    // Nothing was dropped, nothing was rewritten, and `.fail` -- which
    // refuses a record the writer did not finish -- has nothing to refuse.
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail });
        defer journal.deinit(io);
        try testing.expectEqual(@as(u64, 3), try journal.lastSeq(io));
        try testing.expectEqual(@as(usize, 0), journal.dropped_bytes);
        _ = try journal.append(io, 4, created(4, "into the space"));
    }

    var reopened = try Journal.open(testing.allocator, io, ws.path, .{ .on_truncated = .fail });
    defer reopened.deinit(io);
    try testing.expectEqual(@as(u64, 4), try reopened.lastSeq(io));
    try testing.expectEqual(@as(usize, 0), reopened.dropped_bytes);
}

test "a half-written record before the reserved zeros is dropped, and only it" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
        defer journal.deinit(io);
        for (1..4) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }
    const records = try ws.read(try ws.segment(1));
    const torn = "{\"seq\":4,\"at\":4,\"v\":1,\"ev\":{\"crea";
    const crashed = try testing.allocator.alloc(u8, records.len + torn.len + 4096);
    defer testing.allocator.free(crashed);
    @memcpy(crashed[0..records.len], records);
    @memcpy(crashed[records.len..][0..torn.len], torn);
    @memset(crashed[records.len + torn.len ..], 0);
    try ws.write(try ws.segment(1), crashed);

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 3), try journal.lastSeq(io));
    // The count is the bytes somebody wrote, not the zeros nobody did.
    try testing.expectEqual(torn.len, journal.dropped_bytes);
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

test "one pass feeds every fold, and equals the folds fed one at a time" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    for (1..301) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

    var one_at_a_time: [5]Registry = @splat(.{});
    for (&one_at_a_time) |*fold| try journal.subscribe(io, fold.sink());

    var together: [5]Registry = @splat(.{});
    var sinks: [5]Journal.Sink = undefined;
    for (&together, &sinks) |*fold, *sink| sink.* = fold.sink();
    try journal.subscribeAll(io, &sinks);

    for (&together, &one_at_a_time) |shared, separate| {
        try testing.expectEqual(separate, shared);
        try testing.expectEqual(@as(u32, 300), shared.events);
    }

    // And every fold, however it was registered, takes the records that come
    // after it.
    _ = try journal.append(io, 301, created(301, "n"));
    for (&together, &one_at_a_time) |shared, separate| {
        try testing.expectEqual(@as(u64, 301), shared.last);
        try testing.expectEqual(@as(u64, 301), separate.last);
    }
}

test "a fold can be dropped, and stops being called" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
    defer journal.deinit(io);

    var leaving: Registry = .{};
    var staying: Registry = .{};
    try journal.subscribe(io, leaving.sink());
    try journal.subscribe(io, staying.sink());

    _ = try journal.append(io, 1, created(1, "one"));
    try testing.expect(try journal.unsubscribe(io, leaving.sink()));
    _ = try journal.append(io, 2, created(2, "two"));

    try testing.expectEqual(@as(u64, 1), leaving.last);
    try testing.expectEqual(@as(u64, 2), staying.last);
    // A fold that is not registered is not one that can be dropped.
    try testing.expect(!try journal.unsubscribe(io, leaving.sink()));
}

test "a record appended beside a shared subscribe lands in every fold exactly once" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never, .tail_records = 2 });
    defer journal.deinit(io);
    for (1..2_001) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

    // The appender runs while the replay does. Whichever side of the
    // hand-over the record falls on, each fold must see it once and the
    // sequence each fold saw must have no gap and no repeat in it.
    const appender = struct {
        fn f(j: *Journal, inner: Io) void {
            _ = j.append(inner, 2_001, created(2_001, "beside")) catch {};
        }
    }.f;

    var folds: [4]Sequenced = @splat(.{});
    var sinks: [4]Journal.Sink = undefined;
    for (&folds, &sinks) |*fold, *sink| sink.* = fold.sink();

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, appender, .{ &journal, io });
    try journal.subscribeAll(io, &sinks);
    try group.await(io);

    for (&folds) |fold| {
        try testing.expect(fold.ok);
        try testing.expect(fold.seen == 2_000 or fold.seen == 2_001);
        try testing.expectEqual(fold.seen, fold.last);
    }
    // The append either landed in the replay or arrived live, but every fold
    // has to agree about which.
    for (&folds) |fold| try testing.expectEqual(folds[0].seen, fold.seen);
}

/// A fold that only checks the shape of what it is handed: the sequence
/// numbers must arrive in order, one after another, with nothing missing and
/// nothing twice.
const Sequenced = struct {
    seen: u64 = 0,
    last: u64 = 0,
    ok: bool = true,

    fn sink(self: *Sequenced) Journal.Sink {
        return .{ .ctx = self, .f = apply };
    }

    fn apply(ctx: *anyopaque, record: Journal.Record) void {
        const self: *Sequenced = @ptrCast(@alignCast(ctx));
        if (record.seq != self.last + 1) self.ok = false;
        self.last = record.seq;
        self.seen += 1;
    }
};

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

test "stats counts the segments, the records and the bytes they take" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer journal.deinit(io);
    // An empty log has one segment and no records, and says so in numbers
    // rather than in a zero that could mean either.
    try testing.expectEqual(Journal.Stats{
        .segments = 1,
        .records = 0,
        .bytes = 0,
        .oldest_seq = 0,
        .newest_seq = 0,
    }, try journal.stats(io));

    for (1..8) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    const full = try journal.stats(io);
    try testing.expectEqual(@as(usize, 3), full.segments);
    try testing.expectEqual(@as(u64, 7), full.records);
    try testing.expectEqual(@as(u64, 1), full.oldest_seq);
    try testing.expectEqual(@as(u64, 7), full.newest_seq);
    // The bytes are the segment files: the lines and the newlines that end
    // them, and nothing else in the directory.
    const on_disk = (try ws.read(try ws.segment(1))).len +
        (try ws.read(try ws.segment(4))).len +
        (try ws.read(try ws.segment(7))).len;
    try testing.expectEqual(@as(u64, on_disk), full.bytes);

    // Dropping a prefix moves the oldest sequence number and takes the bytes
    // of the segments it unlinked with it.
    _ = try journal.dropSegmentsBefore(io, 3);
    const dropped = try journal.stats(io);
    try testing.expectEqual(@as(usize, 2), dropped.segments);
    try testing.expectEqual(@as(u64, 4), dropped.oldest_seq);
    try testing.expectEqual(@as(u64, 4), dropped.records);
    try testing.expect(dropped.bytes < full.bytes);
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
// Named readers.
//========================================================================

test "a tailer remembers where it got to, in a file of its own" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer journal.deinit(io);
    for (1..10) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));

    // A name that has never committed a cursor starts at the beginning.
    var reports = try journal.tailer(io, "reports");
    defer reports.deinit();
    try testing.expectEqual(@as(u64, 0), reports.cursor);
    try testing.expect(!ws.exists(try ws.sub("reports.cursor")));

    // Read some records, then say so.
    {
        var walk = try reports.replay(io);
        defer walk.deinit(io);
        var seen: u64 = 0;
        while (try walk.next(io)) |record| {
            seen = record.seq;
            if (seen == 4) break;
        }
        try reports.commit(io, seen);
    }
    try testing.expectEqual(@as(u64, 4), reports.cursor);
    try testing.expectEqualStrings("{\"seq\":4}", try ws.read(try ws.sub("reports.cursor")));
    try testing.expect(!ws.exists(try ws.sub("reports.cursor.tmp")));

    // A tailer opened again under the same name is that reader again, and it
    // reads on from where it stopped.
    var again = try journal.tailer(io, "reports");
    defer again.deinit();
    try testing.expectEqual(@as(u64, 4), again.cursor);
    var walk = try again.replay(io);
    defer walk.deinit(io);
    const next = (try walk.next(io)) orelse return error.TestExpectedRecord;
    try testing.expectEqual(@as(u64, 5), next.seq);

    // Two names are two readers, and neither moves the other.
    var audit = try journal.tailer(io, "audit");
    defer audit.deinit();
    try testing.expectEqual(@as(u64, 0), audit.cursor);
    try audit.commit(io, 9);
    var unmoved = try journal.tailer(io, "reports");
    defer unmoved.deinit();
    try testing.expectEqual(@as(u64, 4), unmoved.cursor);

    // A cursor may go backwards, which is how a reader is asked to do a
    // stretch of history over.
    try audit.commit(io, 2);
    try testing.expectEqual(@as(u64, 2), audit.cursor);

    // And forgetting a name puts it back where it started.
    try audit.forget(io);
    try testing.expect(!ws.exists(try ws.sub("audit.cursor")));
    var fresh = try journal.tailer(io, "audit");
    defer fresh.deinit();
    try testing.expectEqual(@as(u64, 0), fresh.cursor);

    // The cursor files sit beside the log and are not part of it.
    try testing.expectEqual(@as(usize, 3), journal.segmentCount());
    try testing.expectEqual(@as(u64, 9), try journal.verify(io));
}

test "a reader's tailer writes its cursor and nothing else" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var writer = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer writer.deinit(io);
    for (1..7) |i| _ = try writer.append(io, @intCast(i), created(@intCast(i), "n"));

    // A `.read` journal takes no lock and writes nothing to the log. Its
    // tailer's cursor is the one file it may create.
    var reader = try Journal.open(testing.allocator, io, ws.path, .{
        .access = .read,
        .tail_records = 1024,
    });
    defer reader.deinit(io);

    var before: [8][]const u8 = undefined;
    var count: usize = 0;
    {
        var it = ws.root.openDir(io, "log", .{ .iterate = true }) catch unreachable;
        defer it.close(io);
        var walk = it.iterate();
        while (try walk.next(io)) |entry| : (count += 1) {
            before[count] = try ws.arena.allocator().dupe(u8, entry.name);
        }
    }

    var follower = try reader.tailer(io, "follower");
    defer follower.deinit();
    try follower.commit(io, 6);
    try testing.expectEqualStrings("{\"seq\":6}", try ws.read(try ws.sub("follower.cursor")));

    // Exactly one new name in the directory, and it is the cursor.
    var added: usize = 0;
    {
        var it = ws.root.openDir(io, "log", .{ .iterate = true }) catch unreachable;
        defer it.close(io);
        var walk = it.iterate();
        while (try walk.next(io)) |entry| {
            var known = false;
            for (before[0..count]) |name| known = known or std.mem.eql(u8, name, entry.name);
            if (!known) {
                added += 1;
                try testing.expectEqualStrings("follower.cursor", entry.name);
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), added);

    // Everything else a reader is refused is still refused.
    try testing.expectError(error.ReadOnly, reader.append(io, 7, created(7, "no")));
    try testing.expectError(error.ReadOnly, reader.snapshot(io, "no"));
}

test "a tailer's name has to be one that can be a file" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    _ = try journal.append(io, 1, created(1, "n"));

    for ([_][]const u8{ "", "..", "a/b", "a\\b", ".hidden", "with space", "sub/dir", "a" ** 65 }) |name| {
        try testing.expectError(error.InvalidName, journal.tailer(io, name));
    }
    var fine = try journal.tailer(io, "a_fine-Name9");
    defer fine.deinit();
    try testing.expectEqual(@as(u64, 0), fine.cursor);

    // A cursor file that is not the object `commit` writes is named, never
    // read as a number that was never reached.
    try ws.write(try ws.sub("broken.cursor"), "{\"seq\":");
    try testing.expectError(error.CorruptCursor, journal.tailer(io, "broken"));
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

    // An index a crash never finished, and one in the format an older
    // version wrote -- which is stale by the same rule and rebuilt the same
    // way, so an old journal opens and keeps working.
    try ws.root.deleteFile(io, try ws.index(1));
    try ws.write(try ws.index(6), "chridx\x01\n" ++ "\xff" ** 8 ++ "\x00" ** 24);

    var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 2));
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 20), try journal.lastSeq(io));

    // A seek into either of those segments still lands on the right record,
    // index or no index.
    for ([_]u64{ 0, 2, 5, 7, 12, 19 }) |cursor| {
        var walk = try journal.replay(io, cursor);
        defer walk.deinit(io);
        const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
        try testing.expectEqual(cursor + 1, record.seq);
    }

    // A call that holds the journal's lock is what builds one: a walk takes
    // no lock and writes nothing.
    try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 1));

    // The missing one was rebuilt on the way, and it describes its segment:
    // a thirty-two byte header and sixteen bytes -- an offset and a
    // timestamp -- for each of the five records.
    try testing.expect(ws.exists(try ws.index(1)));
    try testing.expectEqual(@as(usize, 32 + 5 * 16), (try ws.read(try ws.index(1))).len);
    const rebuilt = try ws.read(try ws.index(1));
    try testing.expectEqualStrings("chridx\x02\n", rebuilt[0..8]);
    try testing.expectEqual(@as(i64, 1), std.mem.readInt(i64, rebuilt[16..24], .little));
    try testing.expectEqual(@as(i64, 5), std.mem.readInt(i64, rebuilt[24..32], .little));
}

test "a clean close leaves an index the next open takes rather than rebuilds" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
        defer journal.deinit(io);
        for (1..2_001) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
        try testing.expectEqual(@as(usize, 1), journal.segmentCount());
    }

    // A mark nothing validates and a rescan would overwrite: the timestamp
    // beside the first record's offset. If the next open rebuilds the index,
    // the mark goes; if it takes the one the close left, the mark stays.
    const sealed = try ws.read(try ws.index(1));
    const marked = try testing.allocator.dupe(u8, sealed);
    defer testing.allocator.free(marked);
    const entry_at = 32 + 8;
    std.mem.writeInt(i64, marked[entry_at..][0..8], -777, .little);
    try ws.write(try ws.index(1), marked);

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never });
        defer journal.deinit(io);
        try testing.expectEqual(@as(u64, 2_000), try journal.lastSeq(io));
        _ = try journal.append(io, 2_001, created(2_001, "n"));
    }

    const after = try ws.read(try ws.index(1));
    try testing.expectEqual(@as(i64, -777), std.mem.readInt(i64, after[entry_at..][0..8], .little));
    // And the index grew by the one record appended after the reopen, rather
    // than being written again from the start.
    try testing.expectEqual(marked.len + 16, after.len);
    try testing.expectEqualStrings(marked[0..8], after[0..8]);
}

test "the index of a sealed segment is checked once, not once a seek" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 1024));
        defer journal.deinit(io);
        for (1..21) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    }

    var journal = try Journal.open(testing.allocator, io, ws.path, small(5, 1));
    defer journal.deinit(io);

    // The first seek into a segment is what checks its index. Every seek
    // after it is a read of eight bytes through a handle that is already
    // open: the index was proved good once and the proof does not expire,
    // because nothing but this process writes the segment.
    {
        var warm = try journal.replay(io, 2);
        defer warm.deinit(io);
        _ = try warm.next(io);
    }
    const before = journal.log.index_opens;
    for (0..10) |_| {
        var walk = try journal.replay(io, 2);
        defer walk.deinit(io);
        const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
        try testing.expectEqual(@as(u64, 3), record.seq);
    }
    try testing.expectEqual(before, journal.log.index_opens);
}

test "a seek into the segment being written to reads its index, not the segment" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // One segment, many records, and a cursor near the end of it. The index of
    // the segment being appended to is the only thing that can turn that into
    // a seek; without it the walk starts at the first record and steps over
    // every one of them.
    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    const count = 5_000;
    for (1..count + 1) |i| _ = try journal.append(io, @intCast(i), created(@intCast(i), "n"));
    try testing.expectEqual(@as(usize, 1), journal.segmentCount());

    var walk = try journal.replay(io, count - 2);
    defer walk.deinit(io);
    const landed = walk.scan.position;
    const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
    try testing.expectEqual(@as(u64, count - 1), record.seq);

    // Where the walk began: inside the last percent of the segment, which is
    // where the record it was asked for is.
    const bytes = journal.log.segments.items[0].bytes;
    try testing.expect(landed > bytes - bytes / 100);
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
    {
        var walk = try journal.replay(io, 2);
        defer walk.deinit(io);
        const record = (try walk.next(io)) orelse return error.TestExpectedRecord;
        try testing.expectEqual(@as(u64, 3), record.seq);
    }
    try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 1));
    try testing.expectEqualStrings(good, try ws.read(try ws.index(1)));
}

//========================================================================
// Lookup by time.
//========================================================================

test "seqAtOrAfter finds the first record at or after a moment" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
        defer journal.deinit(io);

        // An empty log has nothing at any moment.
        try testing.expectEqual(@as(?u64, null), try journal.seqAtOrAfter(io, 0));

        // Nine records at 100, 200, ... 900, over three segments.
        for (1..10) |i| _ = try journal.append(io, @intCast(i * 100), created(@intCast(i), "n"));
        try testing.expectEqual(@as(usize, 3), journal.segmentCount());

        // Before everything, exactly on a record, and between two of them.
        try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, std.math.minInt(i64)));
        try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 100));
        try testing.expectEqual(@as(?u64, 2), try journal.seqAtOrAfter(io, 101));
        try testing.expectEqual(@as(?u64, 5), try journal.seqAtOrAfter(io, 500));
        try testing.expectEqual(@as(?u64, 9), try journal.seqAtOrAfter(io, 900));

        // Past the newest record there is nothing yet -- not record nine.
        try testing.expectEqual(@as(?u64, null), try journal.seqAtOrAfter(io, 901));
        try testing.expectEqual(@as(?u64, null), try journal.seqAtOrAfter(io, std.math.maxInt(i64)));
    }

    // The answer survives a reopen, where the timestamps of the sealed
    // segments come back from their index headers rather than from appends.
    var reopened = try Journal.open(testing.allocator, io, ws.path, small(3, 1024));
    defer reopened.deinit(io);
    try testing.expectEqual(@as(?u64, 4), try reopened.seqAtOrAfter(io, 350));
    try testing.expectEqual(@as(?u64, 9), try reopened.seqAtOrAfter(io, 850));
    try testing.expectEqual(@as(?u64, null), try reopened.seqAtOrAfter(io, 901));
}

test "an out-of-order timestamp is found, not assumed away" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    var journal = try Journal.open(testing.allocator, io, ws.path, small(2, 1024));
    defer journal.deinit(io);

    // Nothing makes a caller pass its timestamps in order, so nothing here
    // bisects: record 2 is older than record 1, and record 5 is older than
    // everything before it.
    const stamps = [_]i64{ 500, 100, 600, 700, 50, 800 };
    for (stamps, 1..) |at, i| _ = try journal.append(io, at, created(@intCast(i), "n"));

    // The lowest sequence number whose `at` reaches the moment -- which for 50
    // is record 5, sitting in the middle of the log.
    try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 50));
    try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 500));
    try testing.expectEqual(@as(?u64, 3), try journal.seqAtOrAfter(io, 501));
    try testing.expectEqual(@as(?u64, 6), try journal.seqAtOrAfter(io, 750));
    try testing.expectEqual(@as(?u64, null), try journal.seqAtOrAfter(io, 801));
    // Record 5, at 50, is the oldest moment in the log and sits in the middle
    // of it. Asking for 750 still answers 6 and not 5, and asking for 801
    // still answers nothing, both of which a search that assumed the stamps
    // rose with the sequence could get wrong.
    try testing.expectEqual(@as(?u64, 4), try journal.seqAtOrAfter(io, 700));

    // A negative timestamp is a timestamp.
    var back = try Workspace.init("back");
    defer back.deinit();
    var earlier = try Journal.open(testing.allocator, io, back.path, small(2, 1024));
    defer earlier.deinit(io);
    for ([_]i64{ -500, -100, -900 }, 1..) |at, i| {
        _ = try earlier.append(io, at, created(@intCast(i), "n"));
    }
    try testing.expectEqual(@as(?u64, 1), try earlier.seqAtOrAfter(io, -1_000));
    try testing.expectEqual(@as(?u64, 1), try earlier.seqAtOrAfter(io, -500));
    try testing.expectEqual(@as(?u64, 2), try earlier.seqAtOrAfter(io, -499));
    try testing.expectEqual(@as(?u64, null), try earlier.seqAtOrAfter(io, 0));
}

test "a lookup by time rebuilds a stale index and reads the rest from it" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        for (1..13) |i| _ = try journal.append(io, @intCast(i * 10), created(@intCast(i), "n"));
    }

    // One index gone, one in the older format, one full of nonsense: none of
    // them is an answer, and all of them are rebuilt on the way past.
    try ws.root.deleteFile(io, try ws.index(1));
    try ws.write(try ws.index(5), "chridx\x01\n" ++ "\x00" ** 24);
    try ws.write(try ws.index(9), "not an index");

    var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1));
    defer journal.deinit(io);
    try testing.expectEqual(@as(?u64, 3), try journal.seqAtOrAfter(io, 25));
    try testing.expectEqual(@as(?u64, 7), try journal.seqAtOrAfter(io, 65));
    try testing.expectEqual(@as(?u64, 11), try journal.seqAtOrAfter(io, 105));

    // The two sealed ones now describe their segments in the current format,
    // timestamps and all. The newest is the active segment, whose index is
    // not sealed until it is rotated away from or the journal is closed.
    for ([_]u64{ 1, 5 }) |base| {
        const bytes = try ws.read(try ws.index(base));
        try testing.expectEqualStrings("chridx\x02\n", bytes[0..8]);
        try testing.expectEqual(@as(usize, 32 + 4 * 16), bytes.len);
        try testing.expectEqual(@as(i64, @intCast(base * 10)), std.mem.readInt(i64, bytes[16..24], .little));
        try testing.expectEqual(@as(i64, @intCast((base + 3) * 10)), std.mem.readInt(i64, bytes[24..32], .little));
    }

    // A reader cannot write an index, and answers anyway.
    var reader = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read, .tail_records = 4 });
    defer reader.deinit(io);
    try ws.write(try ws.index(1), "gone again");
    try testing.expectEqual(@as(?u64, 3), try reader.seqAtOrAfter(io, 25));
    try testing.expectEqualStrings("gone again", try ws.read(try ws.index(1)));
}

test "a record with no timestamp is named rather than stepped over" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();

    // A hand-written record with no `at`, in a sealed segment, in a journal
    // whose tail does not reach back far enough to have read it. Every path
    // that does read one refuses it as `CorruptRecord` already; this is the
    // one that goes looking for records it has not parsed.
    try ws.write(try ws.segment(1), "{\"seq\":1,\"at\":10,\"v\":1,\"ev\":{\"removed\":{\"id\":1}}}\n" ++
        "{\"seq\":2,\"v\":1,\"ev\":{\"removed\":{\"id\":2}}}\n" ++
        "{\"seq\":3,\"at\":30,\"v\":1,\"ev\":{\"removed\":{\"id\":3}}}\n");
    try ws.write(try ws.segment(4), "{\"seq\":4,\"at\":40,\"v\":1,\"ev\":{\"removed\":{\"id\":4}}}\n");

    var journal = try Journal.open(testing.allocator, io, ws.path, .{ .tail_records = 0 });
    defer journal.deinit(io);
    try testing.expectEqual(@as(u64, 4), try journal.lastSeq(io));

    // The segment holding it has no range to skip by, so the lookup goes into
    // it and says what it found rather than stepping over the record.
    try testing.expectError(error.CorruptRecord, journal.seqAtOrAfter(io, 25));
    // And the segment after it still answers, because the refusal is about
    // one segment and not about the log.
    try testing.expectEqual(@as(?u64, 1), try journal.seqAtOrAfter(io, 5));
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
// Backup.
//========================================================================

test "a backup is a whole journal, snapshot and indexes and all" {
    const io = testing.io;
    var ws = try Workspace.init("log");
    defer ws.deinit();
    const copy_path = try ws.beside("copy");

    var whole: Registry = .{};
    var copied: u64 = 0;
    {
        var journal = try Journal.open(testing.allocator, io, ws.path, small(4, 1024));
        defer journal.deinit(io);
        try journal.subscribe(io, whole.sink());
        for (1..12) |i| _ = try journal.append(io, @intCast(i * 10), created(@intCast(i), "n"));
        try journal.snapshot(io, std.mem.asBytes(&whole));
        _ = try journal.append(io, 120, created(12, "after the snapshot"));

        copied = try journal.backup(io, copy_path);
        try testing.expectEqual(@as(u64, 12), copied);

        // A copy over the journal's own directory would truncate the segments
        // it was reading, so it is refused by name.
        try testing.expectError(error.BackupInPlace, journal.backup(io, ws.path));
    }

    // What went into the copy, before anything opens it and adds to it: the
    // three segments, the snapshot, the indexes of the two sealed segments --
    // and no lock, which is this directory's and not the copy's.
    {
        var listing = try ws.root.openDir(io, "copy", .{ .iterate = true });
        defer listing.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(testing.allocator);
        var walk = listing.iterate();
        while (try walk.next(io)) |entry| {
            try names.append(testing.allocator, try ws.arena.allocator().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        try testing.expectEqual(@as(usize, 6), names.items.len);
        try testing.expectEqualStrings("00000000000000000001.idx", names.items[0]);
        try testing.expectEqualStrings("00000000000000000001.log", names.items[1]);
        try testing.expectEqualStrings("00000000000000000005.idx", names.items[2]);
        try testing.expectEqualStrings("00000000000000000005.log", names.items[3]);
        // The newest segment's index describes bytes that were still
        // arriving, so it is left behind and the copy builds its own.
        try testing.expectEqualStrings("00000000000000000009.log", names.items[4]);
        try testing.expectEqualStrings(chronicle.snapshot_name, names.items[5]);
    }

    // The copy opens, holds the same records byte for byte, and carries the
    // snapshot that was beside them.
    const opened = try Journal.openWithSnapshot(testing.allocator, io, copy_path, small(4, 1024));
    var copy = opened.journal;
    defer copy.deinit(io);
    const snapshot = opened.snapshot orelse return error.TestExpectedSnapshot;
    defer testing.allocator.free(snapshot.state);
    try testing.expectEqual(@as(u64, 11), snapshot.seq);

    try testing.expectEqual(copied, try copy.lastSeq(io));
    try testing.expectEqual(copied, try copy.verify(io));
    try testing.expectEqual(@as(usize, 3), copy.segmentCount());

    var refolded: Registry = .{};
    try copy.subscribe(io, refolded.sink());
    try testing.expectEqual(whole, refolded);

    // And the copy goes on from where it was cut.
    try testing.expectEqual(@as(u64, 13), try copy.append(io, 130, created(13, "onwards")));
}

/// One line of a helper's output. `takeDelimiterExclusive` leaves the newline
/// where it is, so the next call would answer with nothing at all.
fn helperLine(reader: *Io.Reader) ![]const u8 {
    const text = try reader.takeDelimiterExclusive('\n');
    _ = reader.takeByte() catch {};
    return text;
}

/// The helper's event type, so a test can read back what the second process
/// wrote. The helper appends nothing else.
const Ping = union(enum) { ping: u32 };
const PingJournal = chronicle.Journal(Ping);

test "a backup taken while another process appends opens as a journal" {
    const io = testing.io;
    const helper = testing.environ.getAlloc(testing.allocator, "CHRONICLE_LOCK_HELPER") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(helper);

    var ws = try Workspace.init("log");
    defer ws.deinit();

    // A writer in another process, appending as fast as it can. Nothing in
    // this process can hold it still: that is what makes the copy hot.
    var child = try std.process.spawn(io, .{
        .argv = &.{ helper, ws.path, "20000" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    var buffer: [64]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &buffer);
    try testing.expectEqualStrings("locked", try helperLine(&out.interface));
    try testing.expectEqualStrings("appending", try helperLine(&out.interface));

    // A reader takes no lock, so this one runs beside the writer.
    var reader = try PingJournal.open(testing.allocator, io, ws.path, .{
        .access = .read,
        .tail_records = 0,
    });
    defer reader.deinit(io);

    // Three copies at three moments. Each has to be a journal: a continuous
    // run of records from the first to the last, every checksum right, and
    // able to carry on.
    var previous: u64 = 0;
    for (0..3) |round| {
        var destination: [16]u8 = undefined;
        const copy_path = try ws.beside(try std.fmt.bufPrint(&destination, "copy{d}", .{round}));

        // Read the growing log back repeatedly first. A walk that runs out of
        // file part-way through a record has to say so, even when the writer
        // has appended more by the time it looks again: the record it was
        // reading is still half a record.
        for (0..8) |_| try reader.refresh(io);
        const copied = try reader.backup(io, copy_path);
        try testing.expect(copied >= previous);
        previous = copied;

        var copy = try PingJournal.open(testing.allocator, io, copy_path, .{
            .verify = .full,
            .tail_records = 4,
        });
        defer copy.deinit(io);

        // `.verify = .full` has already read every record of every segment
        // through the checksum and the sequence; this says how many there
        // were and that the copy agrees with what backup reported.
        try testing.expectEqual(copied, try copy.lastSeq(io));
        try testing.expectEqual(copied, try copy.verify(io));
        try testing.expectEqual(@as(u64, 1), copy.oldestSeq());
        try testing.expectEqual(copied + 1, try copy.append(io, 0, .{ .ping = 7 }));
    }

    // The writer is still the writer, and this process still cannot be one.
    try testing.expectError(error.Locked, PingJournal.open(testing.allocator, io, ws.path, .{}));

    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
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
