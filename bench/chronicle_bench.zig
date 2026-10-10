//! The journal's throughput jobs. With no arguments it runs every workload
//! in turn in the working directory, a million records each (ten thousand
//! for the per-record fsync); `--smoke` runs them all at their smallest. One
//! workload alone:
//!
//!   chronicle-bench WORKLOAD INPUT PATH COUNT [MORE]
//!
//! INPUT is COUNT records of 200 bytes, `{"value":1,"padding":"xxx…"}` and a
//! newline each; `chronicle-bench input INPUT - COUNT` writes it. PATH is the
//! journal directory a workload writes, or reads after `prepare` (or
//! `raw_prepare`, whose INPUT is any JSON Lines file) wrote it there. Every
//! workload prints tab-separated rows: `chronicle`, the workload, the metric,
//! its value and its unit.
//!
//! Workloads: `input`, `prepare`, `append_no_fsync`, `append_fsync`,
//! `group_commit`, `atomic_commit` and `atomic_commit_baseline` (the same
//! batches as a group), `append_if` and `append_if_baseline`, `replay_all`,
//! `replay_from_n FROM [REPETITIONS]`, `follow_replay`, `follow_resume` and
//! `follow_rearm` `[WAKES]`, `clean_reopen [REPETITIONS]`, `raw_prepare`,
//! `raw_append` and `raw_replay_all`.
/// Set once by `main` from `--smoke`: every workload once, at its smallest,
/// reading no clock, as `zig build test` runs it to keep it working.
var smoke = false;
const std = @import("std");
const chronicle = @import("chronicle");
const strand = @import("strand");

const record_bytes: usize = 200;
const prefix = "{\"value\":1,\"padding\":\"";

const Event = struct {
    value: u64,
    padding: []const u8,
};

const Journal = chronicle.Journal(Event);

/// One input record: the bytes every workload appends, 200 of them.
const input_line = prefix ++ @as([record_bytes - prefix.len - 3]u8, @splat('x')) ++ "\"}\n";

/// Write `count` records to `path`.
fn writeInput(io: std.Io, path: []const u8, count: usize) !void {
    if (count == 0) return error.InvalidCount;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var offset: u64 = 0;
    for (0..count) |_| {
        try file.writePositionalAll(io, input_line, offset);
        offset += input_line.len;
    }
}

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
        .tail_records = .fromRaw(0),
        .tail_bytes = .fromRaw(0),
        .max_segment_bytes = .fromRaw(8 * 1024 * 1024),
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

/// `writeBatches`, each batch all or nothing.
fn writeAtomicBatches(journal: *Journal, io: std.Io, input: Input, batch_len: usize) !void {
    var entries: [1000]Journal.Entry = undefined;
    var offset: usize = 0;
    while (offset < input.count) {
        const take = @min(batch_len, input.count - offset);
        for (entries[0..take], 0..) |*entry, i| {
            entry.* = .{ .at = @intCast(offset + i + 1), .event = input.event };
        }
        _ = try journal.appendAll(io, entries[0..take], .atomic);
        offset += take;
    }
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
        _ = try journal.appendAll(io, entries[0..take], .group);
        offset += take;
    }
}

fn prepare(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, path: []const u8, count: usize) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    reset(io, path);
    const journal = try Journal.open(gpa, io, path, options(.never, .write));
    defer journal.deinit(io);
    try writeBatches(journal, io, input, 1000);
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
    // A baseline does the plain operation and is reported under the name of
    // the one it is the baseline of, so the two are compared row for row.
    const baseline = std.mem.endsWith(u8, workload, "_baseline");
    const name = if (baseline) workload[0 .. workload.len - "_baseline".len] else workload;
    const policy: chronicle.Sync = if (std.mem.eql(u8, workload, "append_no_fsync") or std.mem.startsWith(u8, workload, "append_if")) .never else .always;
    const journal = try Journal.open(gpa, io, path, options(policy, .write));
    defer journal.deinit(io);

    const started = benchmarkNow(io);
    if (std.mem.eql(u8, workload, "group_commit") or std.mem.eql(u8, workload, "atomic_commit_baseline")) {
        try writeBatches(journal, io, input, 100);
    } else if (std.mem.eql(u8, workload, "atomic_commit")) {
        try writeAtomicBatches(journal, io, input, 100);
    } else if (std.mem.eql(u8, workload, "append_if")) {
        // One writer, its expectation always met: what the comparison under
        // the lock costs beside `append_no_fsync`.
        for (0..count) |i| _ = try journal.appendIf(io, .{ .last = .fromRaw(i) }, @intCast(i + 1), input.event);
    } else {
        for (0..count) |i| _ = try journal.append(io, @intCast(i + 1), input.event);
    }
    const elapsed = seconds(started, io);
    try printMetric(io, name, "records_per_second", @as(f64, @floatFromInt(count)) / elapsed, "records/s");
    if (std.mem.startsWith(u8, workload, "atomic_commit") or std.mem.eql(u8, workload, "group_commit")) {
        // What the batch members cost on the disk: bytes per record.
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var bytes: u64 = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, chronicle.segment_extension)) continue;
            const file = try dir.openFile(io, entry.name, .{});
            defer file.close(io);
            bytes += try file.length(io);
        }
        try printMetric(io, name, "bytes_per_record", @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(count)), "B");
    }
    if (std.mem.eql(u8, workload, "append_no_fsync")) {
        const mb = @as(f64, @floatFromInt(input.bytes.len)) / 1_000_000.0;
        try printMetric(io, workload, "megabytes_per_second", mb / elapsed, "MB/s");
    }
}

fn replay(io: std.Io, gpa: std.mem.Allocator, path: []const u8, count: usize, from: usize, workload: []const u8, repetitions: usize) !void {
    const journal = try Journal.open(gpa, io, path, options(.never, .read));
    defer journal.deinit(io);
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        const walk = try journal.replay(io, .fromRaw(from - 1));
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
    const journal = try Journal.open(gpa, io, path, options(.never, .write));
    defer journal.deinit(io);
    try writeBatches(journal, io, input, 1000);
    const rearm_at = std.mem.eql(u8, workload, "follow_rearm");
    const resume_at = std.mem.eql(u8, workload, "follow_resume");
    const reusable: ?*Journal.Replay = if (rearm_at) try journal.replayAt(io, .after(.fromRaw(count))) else null;
    defer if (reusable) |walk| walk.deinit(io);

    var cursor: chronicle.Seq = .fromRaw(count);
    var position: chronicle.Position = .after(cursor);
    var elapsed: f64 = 0;
    var seen: usize = 0;
    for (0..wakes) |i| {
        _ = try journal.append(io, @intCast(count + i + 1), input.event);
        const started = benchmarkNow(io);
        if (reusable) |walk| {
            try walk.rearmAt(io, position);
            while (try walk.next(io)) |record| {
                seen += 1;
                cursor = record.seq;
            }
            position = walk.position();
        } else {
            const walk = if (resume_at) try journal.replayAt(io, position) else try journal.replay(io, cursor);
            while (try walk.next(io)) |record| {
                seen += 1;
                cursor = record.seq;
            }
            position = walk.position();
            walk.deinit(io);
        }
        elapsed += seconds(started, io);
    }
    if (seen != wakes or cursor != chronicle.Seq.fromRaw(count + wakes)) return error.FoldMismatch;
    try printMetric(io, workload, "per_wake", elapsed * 1_000_000.0 / @as(f64, @floatFromInt(wakes)), "us");
}

fn reopen(io: std.Io, gpa: std.mem.Allocator, path: []const u8, repetitions: usize) !void {
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        const journal = try Journal.open(gpa, io, path, options(.never, .read));
        elapsed += seconds(started, io);
        if (try journal.lastSeq(io) == chronicle.beginning) return error.EmptyJournal;
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
        .tail_records = .fromRaw(0),
        .tail_bytes = .fromRaw(0),
        .max_segment_bytes = .fromRaw(8 * 1024 * 1024),
        .verify_round_trip = false,
    };
}

/// The whole input file as raw events. The file is the caller's own and the
/// default run's is 200 MB (a million records), so it has no limit: a
/// 64 MiB one stopped the default run at `raw_append` with `StreamTooLong`.
fn loadCorpus(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !struct { bytes: []u8, events: []strand.Raw } {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
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
        const journal = try RawJournal.open(gpa, io, path, rawOptions(.never, .read));
        defer journal.deinit(io);
        const started = benchmarkNow(io);
        const walk = try journal.replay(io, chronicle.beginning);
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
    const journal = try RawJournal.open(gpa, io, path, rawOptions(.never, .write));
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
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    if (all.len == 1 or (all.len == 2 and std.mem.eql(u8, all[1], "--smoke"))) {
        smoke = all.len == 2;
        return everyWorkload(io, gpa);
    }
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const workload = args.next() orelse return error.MissingWorkload;
    const input_path = args.next() orelse return error.MissingInput;
    const path = args.next() orelse return error.MissingPath;
    const count_text = args.next() orelse return error.MissingCount;
    const count = try std.fmt.parseInt(usize, count_text, 10);

    if (std.mem.eql(u8, workload, "input")) return writeInput(io, input_path, count);
    if (std.mem.eql(u8, workload, "prepare")) return prepare(io, gpa, input_path, path, count);
    if (std.mem.eql(u8, workload, "raw_prepare") or std.mem.eql(u8, workload, "raw_append") or
        std.mem.eql(u8, workload, "raw_replay_all"))
    {
        return rawWorkload(io, gpa, input_path, path, count, workload);
    }
    if (std.mem.eql(u8, workload, "append_no_fsync") or
        std.mem.eql(u8, workload, "append_fsync") or
        std.mem.eql(u8, workload, "group_commit") or std.mem.startsWith(u8, workload, "atomic_commit") or
        std.mem.startsWith(u8, workload, "append_if"))
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

/// Every workload in turn, in the working directory: the input, each append
/// into a fresh journal, then the reads over one prepared journal, and the
/// raw-event case over the same input.
fn everyWorkload(io: std.Io, gpa: std.mem.Allocator) !void {
    const count: usize = if (smoke) 10 else 1_000_000;
    const synced: usize = if (smoke) 2 else 10_000;
    const input = "input.jsonl";
    const scratch = "append";
    const prepared = "journal";
    try writeInput(io, input, count);
    try appendWorkload(io, gpa, input, scratch, count, "append_no_fsync");
    try appendWorkload(io, gpa, input, scratch, synced, "append_fsync");
    inline for (.{ "group_commit", "atomic_commit", "atomic_commit_baseline", "append_if", "append_if_baseline" }) |workload| {
        try appendWorkload(io, gpa, input, scratch, count, workload);
    }
    try prepare(io, gpa, input, prepared, count);
    try replay(io, gpa, prepared, count, 1, "replay_all", 1);
    try replay(io, gpa, prepared, count, count - count / 10, "replay_from_n", if (smoke) 1 else 20);
    try reopen(io, gpa, prepared, if (smoke) 1 else 100);
    inline for (.{ "follow_replay", "follow_resume", "follow_rearm" }) |workload| {
        try follow(io, gpa, input, scratch, count, if (smoke) 2 else 10_000, workload);
    }
    const raw = "raw";
    try rawWorkload(io, gpa, input, raw, count, "raw_append");
    try rawWorkload(io, gpa, input, raw, count, "raw_replay_all");
    reset(io, scratch);
    reset(io, prepared);
    reset(io, raw);
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
