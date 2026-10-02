const smoke = @import("bench_options").smoke;
const std = @import("std");
const chronicle = @import("chronicle");
const ref = @import("compat.zig").ref;
const strand = @import("strand");

const record_bytes: usize = 200;
const prefix = "{\"value\":1,\"padding\":\"";

const Event = struct {
    value: u64,
    padding: []const u8,
};

const Journal = chronicle.Journal(Event);

const Input = struct {
    bytes: []u8,
    event: Event,
    count: usize,

    fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, count: usize) !Input {
        const needed = try std.math.mul(usize, count, record_bytes);
        const all = try gpa.alloc(u8, needed);
        errdefer gpa.free(all);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        if (try file.readPositionalAll(io, all, 0) != needed or count == 0) return error.InvalidInput;
        const first = all[0..record_bytes];
        if (!std.mem.startsWith(u8, first, prefix) or !std.mem.endsWith(u8, first, "\"}\n")) return error.InvalidInput;
        return .{
            .bytes = all,
            .event = .{ .value = 1, .padding = first[prefix.len .. record_bytes - 3] },
            .count = count,
        };
    }

    fn deinit(input: *Input, gpa: std.mem.Allocator) void {
        gpa.free(input.bytes);
        input.* = undefined;
    }
};

fn options(sync: chronicle.Sync, access: chronicle.Access) Journal.Options {
    return .{
        .access = access,
        .sync = sync,
        .tail_records = 0,
        .tail_bytes = 0,
        .max_segment_bytes = 8 * 1024 * 1024,
        .verify_round_trip = false,
    };
}

fn reset(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn seconds(started: std.Io.Timestamp, io: std.Io) f64 {
    const ns = started.durationTo(benchmarkNow(io)).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

fn printMetric(io: std.Io, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print("chronicle\t{s}\t{s}\t{d:.6}\t{s}\n", .{ workload, metric, value, unit });
    try out.interface.flush();
}

fn writeBatches(journal: *Journal, io: std.Io, input: Input, batch_len: usize) !void {
    var entries: [1000]Journal.Entry = undefined;
    if (batch_len > entries.len) return error.InvalidBatch;
    var offset: usize = 0;
    while (offset < input.count) {
        const take = @min(batch_len, input.count - offset);
        for (entries[0..take], 0..) |*entry, i| {
            entry.* = .{ .at = @intCast(offset + i + 1), .event = input.event };
        }
        _ = try journal.appendAll(io, entries[0..take]);
        offset += take;
    }
}

fn prepare(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, path: []const u8, count: usize) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    reset(io, path);
    var journal = try Journal.open(gpa, io, path, options(.never, .write));
    defer journal.deinit(io);
    try writeBatches(ref(&journal), io, input, 1000);
}

fn appendWorkload(
    io: std.Io,
    gpa: std.mem.Allocator,
    input_path: []const u8,
    path: []const u8,
    count: usize,
    workload: []const u8,
) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    reset(io, path);
    const policy: chronicle.Sync = if (std.mem.eql(u8, workload, "append_no_fsync")) .never else .always;
    var journal = try Journal.open(gpa, io, path, options(policy, .write));
    defer journal.deinit(io);

    const started = benchmarkNow(io);
    if (std.mem.eql(u8, workload, "group_commit")) {
        try writeBatches(ref(&journal), io, input, 100);
    } else {
        for (0..count) |i| _ = try journal.append(io, @intCast(i + 1), input.event);
    }
    const elapsed = seconds(started, io);
    try printMetric(io, workload, "records_per_second", @as(f64, @floatFromInt(count)) / elapsed, "records/s");
    if (std.mem.eql(u8, workload, "append_no_fsync")) {
        const mb = @as(f64, @floatFromInt(input.bytes.len)) / 1_000_000.0;
        try printMetric(io, workload, "megabytes_per_second", mb / elapsed, "MB/s");
    }
}

fn replay(io: std.Io, gpa: std.mem.Allocator, path: []const u8, count: usize, from: usize, workload: []const u8, repetitions: usize) !void {
    var journal = try Journal.open(gpa, io, path, options(.never, .read));
    defer journal.deinit(io);
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        var walk = try journal.replay(io, @intCast(from - 1));
        var seen: usize = 0;
        var sum: u64 = 0;
        while (try walk.next(io)) |record| {
            sum += record.event.value;
            seen += 1;
        }
        walk.deinit(io);
        elapsed += seconds(started, io);
        const expected = count - from + 1;
        if (seen != expected or sum != expected) return error.FoldMismatch;
    }
    if (std.mem.eql(u8, workload, "replay_all")) {
        try printMetric(io, workload, "records_per_second", @as(f64, @floatFromInt(count * repetitions)) / elapsed, "records/s");
    } else {
        try printMetric(io, workload, "elapsed", elapsed * 1000.0 / @as(f64, @floatFromInt(repetitions)), "ms");
    }
}

/// A reader following a live log: `wakes` times, one record is appended
/// (untimed) and the reader reads what is new (timed). `follow_replay`
/// starts each pass with `replay(cursor)`; `follow_resume` with
/// `replayAt(position)`, where the last pass ended; `follow_rearm` keeps one
/// replay and re-arms it from that position. The log starts `count` records long.
fn follow(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, path: []const u8, count: usize, wakes: usize, workload: []const u8) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    reset(io, path);
    var journal = try Journal.open(gpa, io, path, options(.never, .write));
    defer journal.deinit(io);
    try writeBatches(ref(&journal), io, input, 1000);
    const wants_rearm = std.mem.eql(u8, workload, "follow_rearm");
    const rearm_at = wants_rearm and @hasDecl(Journal.Replay, "rearmAt");
    const resume_at = std.mem.eql(u8, workload, "follow_resume") or (wants_rearm and !rearm_at);
    const ReplayOwner = @typeInfo(@typeInfo(@TypeOf(Journal.replay)).@"fn".return_type.?).error_union.payload;
    var reusable: ?ReplayOwner = if (rearm_at) try journal.replayAt(io, .after(count)) else null;
    defer if (reusable) |*walk| ref(walk).deinit(io);

    var cursor: u64 = count;
    var position: chronicle.Position = .after(count);
    var elapsed: f64 = 0;
    var seen: usize = 0;
    for (0..wakes) |i| {
        _ = try journal.append(io, @intCast(count + i + 1), input.event);
        const started = benchmarkNow(io);
        if (reusable) |*walk| {
            if (comptime @hasDecl(Journal.Replay, "rearmAt")) {
                try ref(walk).rearmAt(io, position);
                while (try ref(walk).next(io)) |record| {
                    seen += 1;
                    cursor = record.seq;
                }
                position = ref(walk).position();
            } else return error.UnsupportedWorkload;
        } else {
            var walk = if (resume_at) try journal.replayAt(io, position) else try journal.replay(io, cursor);
            while (try walk.next(io)) |record| {
                seen += 1;
                cursor = record.seq;
            }
            position = walk.position();
            walk.deinit(io);
        }
        elapsed += seconds(started, io);
    }
    if (seen != wakes or cursor != count + wakes) return error.FoldMismatch;
    try printMetric(io, workload, "per_wake", elapsed * 1_000_000.0 / @as(f64, @floatFromInt(wakes)), "us");
}

fn reopen(io: std.Io, gpa: std.mem.Allocator, path: []const u8, repetitions: usize) !void {
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        var journal = try Journal.open(gpa, io, path, options(.never, .read));
        elapsed += seconds(started, io);
        if (try journal.lastSeq(io) == 0) return error.EmptyJournal;
        journal.deinit(io);
    }
    try printMetric(io, "clean_reopen", "elapsed", elapsed * 1000.0 / @as(f64, @floatFromInt(repetitions)), "ms");
}

// Raw-event case: each record carries generated JSON, cycled to `count`.
const RawJournal = chronicle.Journal(strand.Raw);

fn rawOptions(sync: chronicle.Sync, access: chronicle.Access) RawJournal.Options {
    return .{
        .access = access,
        .sync = sync,
        .tail_records = 0,
        .tail_bytes = 0,
        .max_segment_bytes = 8 * 1024 * 1024,
        .verify_round_trip = false,
    };
}

fn loadCorpus(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !struct { bytes: []u8, events: []strand.Raw } {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    var events: std.ArrayList(strand.Raw) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| if (line.len != 0) try events.append(gpa, .{ .bytes = line });
    if (events.items.len == 0) return error.InvalidInput;
    return .{ .bytes = bytes, .events = try events.toOwnedSlice(gpa) };
}

fn rawWorkload(io: std.Io, gpa: std.mem.Allocator, corpus_path: []const u8, path: []const u8, count: usize, workload: []const u8) !void {
    const corpus = try loadCorpus(io, gpa, corpus_path);
    defer gpa.free(corpus.bytes);
    defer gpa.free(corpus.events);
    if (std.mem.eql(u8, workload, "raw_replay_all")) {
        var journal = try RawJournal.open(gpa, io, path, rawOptions(.never, .read));
        defer journal.deinit(io);
        const started = benchmarkNow(io);
        var walk = try journal.replay(io, 0);
        var seen: usize = 0;
        var bytes: usize = 0;
        while (try walk.next(io)) |record| {
            bytes += record.event.bytes.len;
            seen += 1;
        }
        walk.deinit(io);
        const elapsed = seconds(started, io);
        var want: usize = 0;
        for (0..count) |i| want += corpus.events[i % corpus.events.len].bytes.len;
        if (seen != count or bytes != want) return error.FoldMismatch;
        return printMetric(io, workload, "records_per_second", @as(f64, @floatFromInt(count)) / elapsed, "records/s");
    }
    reset(io, path);
    var journal = try RawJournal.open(gpa, io, path, rawOptions(.never, .write));
    defer journal.deinit(io);
    const measuring = std.mem.eql(u8, workload, "raw_append");
    const started = if (measuring) benchmarkNow(io) else std.Io.Timestamp{ .nanoseconds = 0 };
    for (0..count) |i| _ = try journal.append(io, @intCast(i + 1), corpus.events[i % corpus.events.len]);
    const elapsed = if (measuring) seconds(started, io) else 1;
    if (measuring) {
        try printMetric(io, workload, "records_per_second", @as(f64, @floatFromInt(count)) / elapsed, "records/s");
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const workload = args.next() orelse return error.MissingWorkload;
    const input_path = args.next() orelse return error.MissingInput;
    const path = args.next() orelse return error.MissingPath;
    const count_text = args.next() orelse return error.MissingCount;
    const count = try std.fmt.parseInt(usize, count_text, 10);

    if (std.mem.eql(u8, workload, "prepare")) return prepare(io, gpa, input_path, path, count);
    if (std.mem.eql(u8, workload, "raw_prepare") or std.mem.eql(u8, workload, "raw_append") or
        std.mem.eql(u8, workload, "raw_replay_all"))
    {
        return rawWorkload(io, gpa, input_path, path, count, workload);
    }
    if (std.mem.eql(u8, workload, "append_no_fsync") or
        std.mem.eql(u8, workload, "append_fsync") or
        std.mem.eql(u8, workload, "group_commit"))
    {
        return appendWorkload(io, gpa, input_path, path, count, workload);
    }
    if (std.mem.eql(u8, workload, "replay_all")) return replay(io, gpa, path, count, 1, workload, 1);
    if (std.mem.eql(u8, workload, "replay_from_n")) {
        const from_text = args.next() orelse return error.MissingFrom;
        const from = try std.fmt.parseInt(usize, from_text, 10);
        const repetitions = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 1;
        return replay(io, gpa, path, count, from, workload, repetitions);
    }
    if (std.mem.eql(u8, workload, "follow_replay") or std.mem.eql(u8, workload, "follow_resume") or
        std.mem.eql(u8, workload, "follow_rearm"))
    {
        const wakes = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 10_000;
        return follow(io, gpa, input_path, path, count, wakes, workload);
    }
    if (std.mem.eql(u8, workload, "clean_reopen")) {
        const repetitions = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 1;
        return reopen(io, gpa, path, repetitions);
    }
    return error.UnknownWorkload;
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
