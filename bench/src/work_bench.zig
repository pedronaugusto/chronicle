const std = @import("std");
const chronicle = @import("chronicle");
const smoke = @import("bench_options").smoke;
const Io = std.Io;
const Event = struct { id: u32, name: []const u8 };
const J = chronicle.Journal(Event);
const Fold = struct {
    seen: u64 = 0,
    fn sink(fold: *Fold) J.Sink {
        return .{ .ctx = fold, .f = accept };
    }
    fn accept(ctx: *anyopaque, record: J.Record) void {
        // safe: sink passes the live Fold pointer supplied as its context.
        const fold: *Fold = @ptrCast(@alignCast(ctx));
        std.debug.assert(record.seq == fold.seen + 1);
        fold.seen = record.seq;
    }
};

fn elapsed(io: Io, start: Io.Timestamp) f64 {
    return @floatFromInt(start.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
}
fn metric(io: Io, name: []const u8, value: f64, unit: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buffer);
    try out.interface.print("chronicle\t{s}\t{d:.3}\t{s}\n", .{ name, value, unit });
    try out.interface.flush();
}
fn fill(journal: *J, io: Io, count: usize) !void {
    const entries: [100]J.Entry = @splat(.{ .at = 1, .event = .{ .id = 1, .name = "a name" } });
    var left = count;
    while (left != 0) {
        const n = @min(left, entries.len);
        _ = try journal.appendAll(io, entries[0..n]);
        left -= n;
    }
}
fn seek(journal: *J, io: Io, cursor: u64, rounds: usize) !f64 {
    const start = Io.Clock.awake.now(io);
    for (0..rounds) |_| {
        var walk = try journal.replay(io, cursor);
        defer walk.deinit(io);
        if ((try walk.next(io)).?.seq != cursor + 1) return error.WrongSequence;
    }
    return elapsed(io, start) / @as(f64, @floatFromInt(rounds));
}
fn seeks(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 20 else 20_000;
    var journal = try J.open(a, io, path, .{
        .sync = .never,
        .tail_records = 4,
        .max_segment_records = count,
        .max_segment_bytes = 1 << 30,
    });
    defer journal.deinit(io);
    try fill(&journal, io, 2 * count - 1);
    const sealed = try seek(&journal, io, count - 2, 20);
    const active = try seek(&journal, io, 2 * count - 3, 20);
    try metric(io, "sealed_seek", sealed, "ns/seek");
    try metric(io, "active_seek", active, "ns/seek");
    try metric(io, "active_over_sealed_seek", active / sealed, "ratio");
}
fn folds(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 20 else 20_000;
    var journal = try J.open(a, io, path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    try fill(&journal, io, count);
    var one: Fold = .{};
    const single_start = Io.Clock.awake.now(io);
    try journal.subscribe(io, one.sink());
    const single = elapsed(io, single_start);
    var five: [5]Fold = @splat(.{});
    var sinks: [5]J.Sink = undefined;
    for (&five, &sinks) |*fold, *sink| sink.* = fold.sink();
    const shared_start = Io.Clock.awake.now(io);
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
    var journal = try J.open(a, io, path, .{ .sync = .never, .tail_records = 4 });
    defer journal.deinit(io);
    const start = Io.Clock.awake.now(io);
    for (0..count) |i| _ = try journal.append(io, @intCast(i), .{ .id = @intCast(i), .name = "a name" });
    const writing = elapsed(io, start);
    var fold: Fold = .{};
    const read_start = Io.Clock.awake.now(io);
    try journal.subscribe(io, fold.sink());
    const reading = elapsed(io, read_start);
    if (fold.seen != count) return error.WrongCount;
    const n: f64 = @floatFromInt(count);
    try metric(io, "append", writing / n, "ns/record");
    try metric(io, "replay", reading / n, "ns/record");
}
fn batches(io: Io, a: std.mem.Allocator, path: []const u8) !void {
    const count: usize = if (smoke) 3 else 300;
    var journal = try J.open(a, io, path, .{ .sync = .always, .tail_records = 4 });
    defer journal.deinit(io);
    const start = Io.Clock.awake.now(io);
    for (0..count) |i| _ = try journal.append(io, @intCast(i), .{ .id = @intCast(i), .name = "a name" });
    const single = elapsed(io, start);
    const batch_start = Io.Clock.awake.now(io);
    try fill(&journal, io, count);
    const batched = elapsed(io, batch_start);
    if (try journal.lastSeq(io) != 2 * count) return error.WrongCount;
    try metric(io, "durable_singly", single, "ns");
    try metric(io, "durable_batched", batched, "ns");
    try metric(io, "single_over_batch", single / batched, "ratio");
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedNewScratchDirectory;
    const io = init.io;
    const a = init.gpa;
    // Exclusive creation makes each invocation own all of its scratch.
    try Io.Dir.cwd().createDir(io, args[1], .default_dir);
    defer Io.Dir.cwd().deleteTree(io, args[1]) catch {};
    inline for (.{ .{ "seek", seeks }, .{ "fold", folds }, .{ "rates", rates }, .{ "batch", batches } }) |work| {
        const path = try std.fs.path.join(a, &.{ args[1], work[0] });
        defer a.free(path);
        try work[1](io, a, path);
    }
}
