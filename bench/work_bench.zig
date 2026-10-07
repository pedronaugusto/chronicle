//! Counted work beside the throughput jobs: seeks into a sealed and the
//! active segment, one fold and five, append and replay cost per record,
//! durable appends one at a time and batched, and opening a 200,000-record
//! journal with the default tail.
//!
//!   work-bench [SCRATCH | --smoke]
//!
//! SCRATCH is a directory this invocation creates, owns and removes;
//! `scratch` in the working directory when none is named. `--smoke` runs
//! each job once at its smallest. Every
//! row is tab-separated: `chronicle`, the job, `elapsed` or `ratio`, the
//! value and its unit.
const std = @import("std");
const chronicle = @import("chronicle");
/// Set once by `main` from `--smoke`: every workload once, at its smallest,
/// reading no clock, as `zig build test` runs it to keep it working.
var smoke = false;
const Io = std.Io;
const Event = struct { id: u32, name: []const u8 };
const J = chronicle.Journal(Event);
const Fold = struct {
    seen: u64 = 0,
    fn sink(fold: *Fold) J.Sink {
        return .{ .ctx = fold, .f = accept };
    }
    fn accept(ctx: *anyopaque, record: J.Record) void {
        const fold: *Fold = @ptrCast(@alignCast(ctx)); // safe: sink passes the live Fold pointer supplied as its context.
        std.debug.assert(record.seq == fold.seen + 1);
        fold.seen = record.seq;
    }
};

fn elapsed(io: Io, start: Io.Timestamp) f64 {
    return @floatFromInt(start.durationTo(benchmarkNow(io)).toNanoseconds());
}
fn metric(io: Io, name: []const u8, value: f64, unit: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buffer);
    // Five columns: a ratio is named `ratio`, everything else `elapsed`.
    const kind = if (std.mem.eql(u8, unit, "ratio")) "ratio" else "elapsed";
    try out.interface.print("chronicle\t{s}\t{s}\t{d:.3}\t{s}\n", .{ name, kind, value, unit });
    try out.interface.flush();
}
fn fill(journal: *J, io: Io, count: usize) !void {
    const entries: [100]J.Entry = @splat(.{ .at = 1, .event = .{ .id = 1, .name = "a name" } });
    var left = count;
    while (left != 0) {
        const n = @min(left, entries.len);
        _ = try journal.appendAll(io, entries[0..n], .group);
        left -= n;
    }
}
fn seek(journal: *J, io: Io, cursor: u64, rounds: usize) !f64 {
    const start = benchmarkNow(io);
    for (0..rounds) |_| {
        const walk = try journal.replay(io, cursor);
        defer walk.deinit(io);
        if ((try walk.next(io)).?.seq != cursor + 1) return error.WrongSequence;
    }
    return elapsed(io, start) / @as(f64, @floatFromInt(rounds));
}
fn seeks(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 20 else 20_000;
    const journal = try J.open(a, io, path, .{
        .sync = .never,
        .tail_records = 4,
        .max_segment_records = count,
        .max_segment_bytes = 1 << 30,
    });
    defer journal.deinit(io);
    try fill(journal, io, 2 * count - 1);
    const sealed = try seek(journal, io, count - 2, if (smoke) 1 else 20);
    const active = try seek(journal, io, 2 * count - 3, if (smoke) 1 else 20);
    try metric(io, "sealed_seek", sealed, "ns/seek");
    try metric(io, "active_seek", active, "ns/seek");
    try metric(io, "active_over_sealed_seek", active / sealed, "ratio");
}
fn folds(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 20 else 20_000;
    const journal = try J.open(a, io, path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    try fill(journal, io, count);
    var one: Fold = .{};
    const single_start = benchmarkNow(io);
    try journal.subscribe(io, one.sink());
    const single = elapsed(io, single_start);
    var five: [5]Fold = @splat(.{});
    var sinks: [5]J.Sink = undefined;
    for (&five, &sinks) |*fold, *sink| sink.* = fold.sink();
    const shared_start = benchmarkNow(io);
    try journal.subscribeAll(io, &sinks);
    const shared = elapsed(io, shared_start);
    for (five) |fold| if (fold.seen != count) return error.WrongCount;
    if (one.seen != count) return error.WrongCount;
    try metric(io, "one_fold", single, "ns");
    try metric(io, "five_folds", shared, "ns");
    try metric(io, "five_over_one_fold", shared / single, "ratio");
}
fn rates(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 20 else 50_000;
    const journal = try J.open(a, io, path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    const start = benchmarkNow(io);
    for (0..count) |i| _ = try journal.append(io, @intCast(i), .{ .id = @intCast(i), .name = "a name" });
    const writing = elapsed(io, start);
    var fold: Fold = .{};
    const read_start = benchmarkNow(io);
    try journal.subscribe(io, fold.sink());
    const reading = elapsed(io, read_start);
    if (fold.seen != count) return error.WrongCount;
    const n: f64 = @floatFromInt(count);
    try metric(io, "append", writing / n, "ns/record");
    try metric(io, "replay", reading / n, "ns/record");
}
fn batches(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 3 else 300;
    const journal = try J.open(a, io, path, .{ .sync = .always, .tail_records = 4 });
    defer journal.deinit(io);
    const start = benchmarkNow(io);
    for (0..count) |i| _ = try journal.append(io, @intCast(i), .{ .id = @intCast(i), .name = "a name" });
    const single = elapsed(io, start);
    const batch_start = benchmarkNow(io);
    try fill(journal, io, count);
    const batched = elapsed(io, batch_start);
    if (try journal.lastSeq(io) != 2 * count) return error.WrongCount;
    try metric(io, "durable_singly", single, "ns");
    try metric(io, "durable_batched", batched, "ns");
    try metric(io, "single_over_batch", single / batched, "ratio");
}

// Opening keeps the default verification and tail, and has 30 seconds; the
// fixture is written untimed.
fn largeOpen(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const LargeEvent = union(enum) { created: struct { id: u32, name: []const u8 } };
    const LargeJournal = chronicle.Journal(LargeEvent);
    const count: usize = if (smoke) 20 else 200_000;
    {
        const journal = try LargeJournal.open(a, io, path, .{ .sync = .never, .tail_records = 0 });
        defer journal.deinit(io);
        var entries: [500]LargeJournal.Entry = undefined;
        var offset: usize = 0;
        while (offset < count) {
            const n = @min(count - offset, entries.len);
            for (entries[0..n], 0..) |*entry, i| entry.* = .{
                .at = @intCast(offset + i),
                .event = .{ .created = .{ .id = @intCast(offset + i), .name = "a name of some length" } },
            };
            _ = try journal.appendAll(io, entries[0..n], .group);
            offset += n;
        }
        const segments = try journal.segmentCount(io);
        if (!smoke and segments <= 1) return error.ExpectedMultipleSegments;
    }
    const started = benchmarkNow(io);
    const journal = try LargeJournal.open(a, io, path, .{});
    defer journal.deinit(io);
    const elapsed_ms = started.durationTo(benchmarkNow(io)).toMilliseconds();
    if (try journal.lastSeq(io) != count) return error.WrongCount;
    try metric(io, "large_open", @floatFromInt(elapsed_ms), "ms");
    if (!smoke and elapsed_ms >= 30_000) return error.OpenTooSlow;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke");
    // A scratch named on the command line, or one in the working directory.
    const scratch = if (args.len == 2 and !smoke) args[1] else if (args.len <= 2) "scratch" else return error.ExpectedNewScratchDirectory;
    const io = init.io;
    const a = init.gpa;
    // Exclusive creation makes each invocation own all of its scratch.
    try Io.Dir.cwd().createDir(io, scratch, .default_dir);
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    inline for (.{ .{ "seek", seeks }, .{ "fold", folds }, .{ "rates", rates }, .{ "batch", batches }, .{ "large", largeOpen } }) |work| {
        const path = try std.Io.Dir.path.join(a, &.{ scratch, work[0] });
        defer a.free(path);
        try work[1](io, a, path);
    }
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
