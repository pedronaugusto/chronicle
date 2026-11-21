//! Reads by key beside the writer and `buildIndexes`, inside a shakedown
//! `Sim` with airlock's calls routed onto its disk: `explore` runs each
//! scenario once for every schedule within its preemptions. A reader by key
//! walks while the writer seals a segment, builds the files of one sealed
//! without them and compacts it, and a builder writes those files while
//! compaction rewrites the segment.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");

const Event = union(enum) {
    put: struct { key: u64 },

    pub const chronicle = .{ .indexes = &.{
        index("key", 1, .exact, keyOf),
    } };

    const index = @import("chronicle.zig").index;

    fn keyOf(e: Event) ?u64 {
        return e.put.key;
    }
};

const Journal = chronicle.Journal(Event);

const os = builtin.target.os.tag;
/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

/// Each record's key, by seq: the reader asks for key 1.
const keys = [_]u64{ 1, 1, 0, 1, 1 };
const asked = 1;
/// What compaction keeps: the records after this one.
const kept_after = 1;

const options: Journal.Options = .{ .sync = .never, .max_segment_records = .fromRaw(2) };

fn put(journal: *Journal, io: Io, seq: u64) !void {
    _ = try journal.append(io, .fromRaw(@intCast(seq)), .{ .put = .{ .key = keys[seq - 1] } });
}

/// Reads key `asked` from the start: the records come strictly rising, each
/// with the key, and every record with the key that compaction keeps and
/// that was appended before the read began is among them.
fn read(io: Io, journal: *Journal) !void {
    const last = try journal.lastSeq(io);
    const walk = try journal.readIndexed(io, "key", asked, .after(.fromRaw(0)));
    defer walk.deinit(io);
    var seen: chronicle.Seq = .fromRaw(0);
    var found: [keys.len]bool = @splat(false);
    while (try walk.next(io)) |record| {
        if (record.seq.compare(seen) != .gt) return error.RecordsOutOfOrder;
        // Record `seq` was the write of `keys[seq - 1]`.
        const index = (try record.seq.predecessor()).raw();
        if (record.event.put.key != asked or keys[index] != asked) return error.WrongKey;
        found[index] = true;
        seen = record.seq;
    }
    for (keys, 1..) |key, seq| {
        if (key == asked and seq > kept_after and last.compare(.fromRaw(seq)) != .lt and !found[seq - 1]) return error.RecordMissing;
    }
}

/// Builds every sealed segment's missing files, one call a segment.
fn build(io: Io, journal: *Journal) !void {
    while (try journal.buildIndexes(io)) |_| {}
}

/// The writer's steps, in order: appending record 4, appending record 5,
/// which seals segment 3 with its files, building segment 1's files (sealed
/// without them), and a compaction keeping the records after 1, which cuts
/// inside segment 1 and so takes its file away.
const Step = enum { append_4, append_5, build, compact };

/// When the writer takes a step: before the tasks start, while they run, or
/// not at all.
const When = enum { before, during, skip };

/// Which of the reader and the builder run as tasks beside the writer, and
/// when the writer takes each step. A reader that is not a task reads on the
/// writer's task after its steps; with a builder task the writer builds
/// nothing.
const Scenario = struct {
    reader: bool,
    builder: bool,
    steps: std.enums.EnumArray(Step, When),
};

fn take(journal: *Journal, io: Io, step: Step) !void {
    switch (step) {
        .append_4 => try put(journal, io, 4),
        .append_5 => try put(journal, io, 5),
        .build => try build(io, journal),
        .compact => try journal.compact(io, .fromRaw(kept_after)),
    }
}

fn scenario(io: Io, plan: Scenario) !void {
    const h = try seam.Seam.create(testing.allocator, io, .{ .trace = .off });
    defer h.destroy();
    const hooked = h.io();
    {
        const journal = try Journal.open(testing.allocator, hooked, "log", options);
        defer journal.deinit(hooked);
        try put(journal, hooked, 1);
    }
    const journal = try Journal.open(testing.allocator, hooked, "log", options);
    defer journal.deinit(hooked);
    // Segment 1 held a record when the journal opened: it seals without files.
    try put(journal, hooked, 2);
    try put(journal, hooked, 3);
    for (std.enums.values(Step)) |step| if (plan.steps.get(step) == .before) try take(journal, hooked, step);
    {
        var reader: ?Io.Future(@typeInfo(@TypeOf(read)).@"fn".return_type.?) = if (plan.reader) try hooked.concurrent(read, .{ hooked, journal }) else null;
        defer if (reader) |*task| task.cancel(hooked) catch |err| {
            // Cancellation joins the task; its error was checked by await.
            std.log.debug("task cleanup: {t}", .{err});
        };
        var builder: ?Io.Future(@typeInfo(@TypeOf(build)).@"fn".return_type.?) = if (plan.builder) try hooked.concurrent(build, .{ hooked, journal }) else null;
        defer if (builder) |*task| task.cancel(hooked) catch |err| {
            std.log.debug("task cleanup: {t}", .{err});
        };
        for (std.enums.values(Step)) |step| if (plan.steps.get(step) == .during) try take(journal, hooked, step);
        if (!plan.reader) try read(hooked, journal);
        if (reader) |*task| try task.await(hooked);
        if (builder) |*task| try task.await(hooked);
    }
    // Afterwards every sealed segment has its files, and a read finds every kept record.
    try build(hooked, journal);
    const status = try journal.indexStatus(hooked);
    if (status.indexes[0].missing != 0) return error.FilesMissing;
    try read(hooked, journal);
}

fn body(plan: Scenario, c: *shakedown.Case) anyerror!void {
    const sim = try c.sim(.{ .fs = .{ .names = names }, .executor = .threads });
    switch (sim.run(scenario, .{ sim.io(), plan })) {
        .finished => {},
        .failed => |err| return err,
        else => return error.Unfinished,
    }
}

fn explore(plan: Scenario, preemptions: u8) !void {
    const searched = try shakedown.explore(testing.allocator, plan, body, .{ .preemptions = preemptions });
    try testing.expect(searched.complete);
    // The tasks take turns: one schedule would prove nothing.
    try testing.expect(searched.runs > 1);
}

test "a read by key meets a build and compaction taking its segment's file in every order within two preemptions" {
    try explore(.{ .reader = true, .builder = false, .steps = .init(.{ .append_4 = .skip, .append_5 = .skip, .build = .during, .compact = .during }) }, 2);
}

test "a read by key meets the writer sealing a segment in every order within one preemption" {
    try explore(.{ .reader = true, .builder = false, .steps = .init(.{ .append_4 = .before, .append_5 = .during, .build = .skip, .compact = .skip }) }, 1);
}

test "a build meets compaction rewriting its segment in every order within two preemptions" {
    try explore(.{ .reader = false, .builder = true, .steps = .init(.{ .append_4 = .skip, .append_5 = .skip, .build = .skip, .compact = .during }) }, 2);
}

test "a read by key and a build meet the writer and each other in every order within one preemption" {
    try explore(.{ .reader = true, .builder = true, .steps = .init(.{ .append_4 = .before, .append_5 = .during, .build = .skip, .compact = .during }) }, 1);
}
