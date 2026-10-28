//! The journal on a reactor runtime, the family's evented `Io`: a program
//! that swaps `Io.Threaded` for `reactor.Runtime` keeps every promise the
//! suite proves on `Io.Threaded`. The suite proper runs there; this holds
//! the runtime to a journal's whole life on it, the parts that wait (a
//! reader parked for the next record, its cancel) above all.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const reactor = @import("reactor");
const chronicle = @import("../chronicle.zig");

const Event = union(enum) { counted: u32 };
const Journal = chronicle.Journal(Event);
const Seq = chronicle.Seq;
const Blocking = @import("airlock").Blocking;

/// The runtime's sync lane (`reactor.syncLane`), as an application wires it
/// into `Options.blocking`, counting each sync on its way: the journal's
/// syncs are proved to go through it, every one, off the runtime's workers.
const Counted = struct {
    syncs: std.atomic.Value(u32) = .init(0),
    lane: Blocking = .{ .run = run },

    fn blocking(c: *Counted) *Blocking {
        return &c.lane;
    }

    fn run(lane: *Blocking, io: Io, job: *Blocking.Job) Io.Cancelable!void {
        const c: *Counted = @alignCast(@fieldParentPtr("lane", lane));
        _ = c.syncs.fetchAdd(1, .monotonic);
        return reactor.syncLane(io, job);
    }

    fn take(c: *Counted) u32 {
        return c.syncs.swap(0, .monotonic);
    }
};

/// Starts a runtime with workers of its own, or skips where this system
/// has no evented backend.
fn start(runtime: *reactor.Runtime) !void {
    runtime.init(testing.allocator, .{ .workers = 2, .max_tasks = 64, .stack_size = .fromRaw(4 << 20) }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer runtime.deinit();
    try runtime.start();
}

fn waitPast(io: Io, journal: *Journal, cursor: Seq) Io.Cancelable!Seq {
    return journal.waitPast(io, cursor);
}

fn count(io: Io, journal: *Journal) !u32 {
    const walk = try journal.replay(io, .fromRaw(0));
    defer walk.deinit(io);
    var n: u32 = 0;
    while (try walk.next(io)) |record| {
        n += 1;
        try testing.expectEqual(n, record.event.counted);
    }
    return n;
}

test "a journal's life on a runtime: appends, a reader woken and one canceled, replay, a backup, compaction, a reopen" {
    var runtime: reactor.Runtime = undefined;
    try start(&runtime);
    defer runtime.deinit();
    const io = runtime.io();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.Io.Dir.path.join(testing.allocator, &.{ root, "log" });
    defer testing.allocator.free(path);
    const copy = try std.Io.Dir.path.join(testing.allocator, &.{ root, "copy" });
    defer testing.allocator.free(copy);
    var counted: Counted = .{};

    {
        const journal = try Journal.open(testing.allocator, io, path, .{ .max_segment_records = chronicle.Records.fromRaw(4), .blocking = counted.blocking() });
        defer journal.deinit(io);
        try testing.expect(counted.take() > 0); // the directory made, and the first segment
        for (1..11) |i| _ = try journal.append(io, .fromRaw(@intCast(i)), .{ .counted = @intCast(i) });
        try testing.expect(counted.take() >= 10); // every append, every rotation

        // A reader parked past the newest record is woken by the next.
        var woken = try io.concurrent(waitPast, .{ io, journal, Seq.fromRaw(10) });
        _ = try journal.append(io, .fromRaw(11), .{ .counted = 11 });
        try testing.expectEqual(Seq.fromRaw(11), try woken.await(io));
        // One parked for a record that never comes ends at its cancel.
        var parked = try io.concurrent(waitPast, .{ io, journal, Seq.fromRaw(100) });
        try testing.expectError(error.Canceled, parked.cancel(io));

        try testing.expectEqual(@as(u32, 11), try count(io, journal));
        _ = counted.take();
        try testing.expectEqual(Seq.fromRaw(11), try journal.backup(io, copy));
        try testing.expect(counted.take() > 0); // the copies' batch
        try journal.compact(io, .fromRaw(4));
        try testing.expect(counted.take() > 0); // the rewritten segment and the directory
        try journal.finish(io);
    }
    const reopened = try Journal.open(testing.allocator, io, path, .{ .verify = .full, .blocking = counted.blocking() });
    defer reopened.deinit(io);
    try testing.expectEqual(Seq.fromRaw(11), try reopened.lastSeq(io));
    const backed = try Journal.open(testing.allocator, io, copy, .{ .verify = .full });
    defer backed.deinit(io);
    try testing.expectEqual(@as(u32, 11), try count(io, backed));
}
