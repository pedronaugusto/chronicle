//! The public operations the throughput jobs do not time. With no
//! arguments it prepares a million-record journal in the working directory
//! and runs every mode in turn; `--smoke` runs them all at their smallest.
//! One mode alone:
//!
//!   cover-bench MODE [DATA] [SCRATCH]
//!
//! DATA is a prepared million-record journal (`chronicle-bench prepare`),
//! opened for reading only. SCRATCH is a directory this invocation owns.
//! Every mode prints timing rows and `checksum` rows: counts, sums and
//! sequence numbers that say the work was done, the same on every run.
//!
//! Modes: `checksum`, `checksum-std` (std's CRC-32/ISCSI over the same
//! buffers, the floor), `verify DATA`, `reopen-full DATA REPETITIONS`,
//! `seek DATA`, `seq-at DATA`, `subscribe-from DATA`, `copy-since SCRATCH`,
//! `refresh SCRATCH`, `wait-past SCRATCH`, `deferred SCRATCH`,
//! `tailer SCRATCH`, `snapshot SCRATCH`, `retention SCRATCH`,
//! `backup DATA DEST`, `backup-copy DATA DEST` (the files copied byte for
//! byte and synced, the floor) and `finish SCRATCH`.
const std = @import("std");
const chronicle = @import("chronicle");
const airlock = @import("airlock");
/// Set once by `main` from `--smoke`: every mode once, at its smallest,
/// reading no clock, as `zig build test` runs it to keep it working.
var smoke = false;
const Io = std.Io;

const Event = struct { value: u64, padding: []const u8 };
const J = chronicle.Journal(Event);
const padding: []const u8 = &@as([172]u8, @splat('x'));
const label = "chronicle";

fn now(io: Io) Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return Io.Clock.awake.now(io);
}
var smoke_ticks = std.atomic.Value(i64).init(0);
fn since(io: Io, started: Io.Timestamp) u64 {
    if (smoke) return 1;
    return @intCast(@max(started.untilNow(io, .awake).toNanoseconds(), 1));
}

var out_buffer: [4096]u8 = undefined;
var out_writer: Io.File.Writer = undefined;
var out: *Io.Writer = undefined;

fn row(workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    try out.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ label, workload, metric, value, unit });
}
fn rate(workload: []const u8, items: u64, elapsed: u64) !void {
    const n: f64 = @floatFromInt(@max(items, 1));
    const t: f64 = @floatFromInt(elapsed);
    try row(workload, "items", n * 1e9 / t, "items/s");
    try row(workload, "per_item", t / n, "ns");
}
fn check(workload: []const u8, metric: []const u8, value: u64) !void {
    try out.print("{s}\t{s}\t{s}\t{d}\tchecksum\n", .{ label, workload, metric, value });
}

fn options(sync: chronicle.Sync, access: chronicle.Access) J.Options {
    return .{ .access = access, .sync = sync, .tail_records = .fromRaw(0), .tail_bytes = .fromRaw(0), .max_segment_bytes = .fromRaw(8 * 1024 * 1024), .verify_round_trip = false };
}

/// Pseudo-random cursors, the same on every run: an LCG, high bits.
const Cursors = struct {
    state: u64 = 0x2545F4914F6CDD1D,
    fn next(c: *Cursors, below: u64) u64 {
        c.state = c.state *% 6364136223846793005 +% 1442695040888963407;
        return (c.state >> 33) % below;
    }
};

fn join(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.Io.Dir.path.join(gpa, &.{ dir, name });
}

fn fill(journal: *J, io: Io, count: usize) !void {
    var entries: [1000]J.Entry = undefined;
    var offset: usize = 0;
    while (offset < count) {
        const n = @min(entries.len, count - offset);
        for (entries[0..n], 0..) |*entry, i| entry.* = .{ .at = @intCast(offset + i + 1), .event = .{ .value = 1, .padding = padding } };
        _ = try journal.appendAll(io, entries[0..n], .group);
        offset += n;
    }
}

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };
    out_writer = Io.File.stdout().writer(io, &out_buffer);
    out = &out_writer.interface;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--smoke"))) {
        smoke = args.len == 2;
        try everyMode(io, gpa);
        return out.flush();
    }
    const Mode = enum { checksum, @"checksum-std", verify, @"reopen-full", seek, @"seq-at", @"subscribe-from", @"copy-since", refresh, @"wait-past", deferred, tailer, snapshot, retention, backup, @"backup-copy", finish };
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.Usage;
    switch (mode) {
        .checksum => try checksums(io, gpa, false),
        .@"checksum-std" => try checksums(io, gpa, true),
        .verify => try verify(io, gpa, args[2]),
        .@"reopen-full" => try reopenFull(io, gpa, args[2], try std.fmt.parseInt(usize, args[3], 10)),
        .seek => try seek(io, gpa, args[2]),
        .@"seq-at" => try seqAt(io, gpa, args[2]),
        .@"subscribe-from" => try subscribeFrom(io, gpa, args[2]),
        .@"copy-since" => try copySince(io, gpa, args[2]),
        .refresh => try refresh(io, gpa, args[2]),
        .@"wait-past" => try waitPast(io, gpa, args[2]),
        .deferred => try deferred(io, gpa, args[2]),
        .tailer => try tailers(io, gpa, args[2]),
        .snapshot => try snapshots(io, gpa, args[2]),
        .retention => try retention(io, gpa, args[2]),
        .backup => try backup(io, gpa, args[2], args[3]),
        .@"backup-copy" => try backupCopy(io, args[2], args[3]),
        .finish => try finish(io, gpa, args[2]),
    }
    try out.flush();
}

/// Every mode in turn, in the working directory: the data journal written
/// first, each scratch mode in a fresh directory of its own.
fn everyMode(io: Io, gpa: std.mem.Allocator) !void {
    const data = "data";
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, data) catch {};
    {
        const journal = try J.open(gpa, io, data, options(.never, .write));
        defer journal.deinit(io);
        try fill(journal, io, if (smoke) 20 else 1_000_000);
    }
    try checksums(io, gpa, false);
    try checksums(io, gpa, true);
    try verify(io, gpa, data);
    try reopenFull(io, gpa, data, if (smoke) 1 else 20);
    try seek(io, gpa, data);
    try seqAt(io, gpa, data);
    try subscribeFrom(io, gpa, data);
    inline for (.{ copySince, refresh, waitPast, deferred, tailers, snapshots, retention, finish }) |mode| {
        const scratch = "scratch";
        cwd.deleteTree(io, scratch) catch {};
        try mode(io, gpa, scratch);
        cwd.deleteTree(io, scratch) catch {};
    }
    try backup(io, gpa, data, "backup");
    try backupCopy(io, data, "backup-copy");
    cwd.deleteTree(io, data) catch {};
}

/// The record checksum over buffers of three sizes, 256 MiB of each.
fn checksums(io: Io, gpa: std.mem.Allocator, comptime std_table: bool) !void {
    const total: usize = if (smoke) 64 * 1024 else 256 << 20;
    const bytes = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    const who = if (std_table) "zig-std" else label;
    inline for (.{ 64, 1024, 64 * 1024 }, .{ "checksum-64", "checksum-1k", "checksum-64k" }) |len, work| {
        var sum: u64 = 0;
        const rounds = total / len;
        const started = now(io);
        for (0..rounds) |i| {
            const piece = bytes[(i * 64) % (bytes.len - len + 1) ..][0..len];
            sum += if (std_table) std.hash.crc.@"CRC-32/ISCSI".hash(piece) else chronicle.checksum(piece);
        }
        const elapsed = since(io, started);
        try out.print("{s}\t{s}\tbytes\t{d:.6}\tMB/s\n", .{ who, work, @as(f64, @floatFromInt(rounds * len)) * 1e3 / @as(f64, @floatFromInt(elapsed)) });
        try out.print("{s}\t{s}\tsum\t{d}\tchecksum\n", .{ who, work, sum });
    }
}

/// `verify` over the prepared journal: every record read and checked.
fn verify(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const started = now(io);
    const records = try journal.verify(io);
    const elapsed = since(io, started);
    try rate("verify", records.raw(), elapsed);
    try check("verify", "records", records.raw());
}

/// `open` with `verify = .full`: the work of a recovery that reads every
/// record.
fn reopenFull(io: Io, gpa: std.mem.Allocator, data: []const u8, repetitions: usize) !void {
    var total: u64 = 0;
    var last: u64 = 0;
    for (0..repetitions) |_| {
        var o = options(.never, .read);
        o.verify = .full;
        const started = now(io);
        const journal = try J.open(gpa, io, data, o);
        total += since(io, started);
        last = (try journal.lastSeq(io)).raw();
        journal.deinit(io);
    }
    try row("clean_reopen", "elapsed", @as(f64, @floatFromInt(total)) / 1e6 / @as(f64, @floatFromInt(repetitions)), "ms");
    try check("clean_reopen", "last", last);
}

/// `replay(cursor)` and one `next`, at 2,000 pseudo-random cursors.
fn seek(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = (try journal.lastSeq(io)).raw();
    const rounds: usize = if (smoke) 1 else 2_000;
    var cursors: Cursors = .{};
    var sum: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const cursor = cursors.next(count);
        const walk = try journal.replay(io, .fromRaw(cursor));
        defer walk.deinit(io);
        const record = (try walk.next(io)) orelse return error.NoRecord;
        if (record.seq != chronicle.Seq.fromRaw(cursor + 1)) return error.WrongSequence;
        sum += record.seq.raw();
    }
    const elapsed = since(io, started);
    try rate("seek", rounds, elapsed);
    try check("seek", "sum", sum);
}

/// `seqAtOrAfter` at 10,000 pseudo-random times (`at` is the record's number).
fn seqAt(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = (try journal.lastSeq(io)).raw();
    const rounds: usize = if (smoke) 1 else 10_000;
    var cursors: Cursors = .{};
    var sum: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const at = cursors.next(count) + 1;
        sum += ((try journal.seqAtOrAfter(io, @intCast(at))) orelse return error.NoRecord).raw();
    }
    const elapsed = since(io, started);
    try rate("seq-at", rounds, elapsed);
    try check("seq-at", "sum", sum);
}

const Fold = struct {
    seen: u64 = 0,
    fn sink(fold: *Fold) J.Sink {
        return .{ .ctx = fold, .f = accept };
    }
    fn accept(ctx: *anyopaque, record: J.Record) void {
        const fold: *Fold = @ptrCast(@alignCast(ctx)); // safe: the sink's context is the live Fold it was made from.
        fold.seen += record.event.value;
    }
};

/// `subscribeFrom` and `subscribeAllFrom` over the last tenth of the journal.
fn subscribeFrom(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    const journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = (try journal.lastSeq(io)).raw();
    const from = count - count / 10;
    {
        var one: Fold = .{};
        const started = now(io);
        try journal.subscribeFrom(io, one.sink(), .fromRaw(from));
        const elapsed = since(io, started);
        _ = try journal.unsubscribe(io, one.sink());
        try rate("subscribe-from", count - from, elapsed);
        try check("subscribe-from", "seen", one.seen);
    }
    {
        var five: [5]Fold = @splat(.{});
        var sinks: [5]J.Sink = undefined;
        for (&five, &sinks) |*fold, *s| s.* = fold.sink();
        const started = now(io);
        try journal.subscribeAllFrom(io, &sinks, .fromRaw(from));
        const elapsed = since(io, started);
        var seen: u64 = 0;
        for (five) |fold| seen += fold.seen;
        try rate("subscribe-all-from", count - from, elapsed);
        try check("subscribe-all-from", "seen", seen);
    }
}

/// `copySince` of the last hundred records, held in the tail.
fn copySince(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(journal, io, 10_000);
    const rounds: usize = if (smoke) 1 else 10_000;
    var records: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const batch = try journal.copySince(gpa, io, .fromRaw(10_000 - 100));
        defer batch.deinit();
        if (!batch.complete()) return error.Incomplete;
        records += batch.records().len;
    }
    const elapsed = since(io, started);
    try rate("copy-since", rounds, elapsed);
    try check("copy-since", "records", records);
}

/// A `.read` journal beside a writer, refreshed after every append.
fn refresh(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const writer = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer writer.deinit(io);
    try fill(writer, io, 1000);
    const reader = try J.open(gpa, io, scratch, options(.never, .read));
    defer reader.deinit(io);
    const rounds: usize = if (smoke) 1 else 1000;
    var total: u64 = 0;
    for (0..rounds) |i| {
        _ = try writer.append(io, @intCast(1001 + i), .{ .value = 1, .padding = padding });
        const started = now(io);
        try reader.refresh(io);
        total += since(io, started);
    }
    const last = (try reader.lastSeq(io)).raw();
    try rate("refresh", rounds, total);
    try check("refresh", "last", last);
}

const Waiter = struct {
    sent_at: std.atomic.Value(i64) = .init(0),
    done: std.atomic.Value(u64) = .init(0),
    /// Set by the waiter however it ends, so that the appender stops
    /// waiting for a record it will never take and awaits the error.
    ended: std.atomic.Value(bool) = .init(false),
    latency: u64 = 0,
};

fn stamp(io: Io) i64 {
    return @intCast(now(io).nanoseconds);
}

/// Wait past each new record and take it in hand: `waitPast`, then
/// `copySince`.
fn wait(io: Io, gpa: std.mem.Allocator, journal: *J, rounds: u64, waiter: *Waiter) !void {
    defer waiter.ended.store(true, .release);
    var cursor: chronicle.Seq = .fromRaw(1000);
    for (0..rounds) |i| {
        while (true) {
            _ = try journal.waitPast(io, cursor);
            const batch = try journal.copySince(gpa, io, cursor);
            defer batch.deinit();
            const newest = if (batch.records().len == 0) cursor else batch.records()[batch.records().len - 1].seq;
            if (newest.compare(cursor) == .gt) {
                cursor = newest;
                break;
            }
        }
        waiter.latency += @intCast(@max(stamp(io) - waiter.sent_at.load(.acquire), 0));
        waiter.done.store(i + 1, .release);
    }
}

fn waitPast(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(journal, io, 1000);
    const rounds: u64 = if (smoke) 2 else 1000;
    var waiter: Waiter = .{};
    var task = try io.concurrent(wait, .{ io, gpa, journal, rounds, &waiter });
    for (0..rounds) |i| {
        waiter.sent_at.store(stamp(io), .release);
        _ = try journal.append(io, @intCast(1001 + i), .{ .value = 1, .padding = padding });
        while (waiter.done.load(.acquire) < i + 1) {
            if (waiter.ended.load(.acquire)) break;
            std.atomic.spinLoopHint();
        }
        if (waiter.done.load(.acquire) < i + 1) break;
    }
    try task.await(io);
    try row("wait-past", "latency", @as(f64, @floatFromInt(waiter.latency)) / @as(f64, @floatFromInt(rounds)) / 1e3, "us");
    try check("wait-past", "records", waiter.done.load(.acquire));
}

/// Under `.always`, deferred appends, then one durable append that makes
/// them durable too.
fn deferred(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const count: usize = if (smoke) 2 else 10_000;
    const journal = try J.open(gpa, io, scratch, options(.always, .write));
    defer journal.deinit(io);
    const started = now(io);
    for (0..count - 1) |i| _ = try journal.appendDeferred(io, @intCast(i + 1), .{ .value = 1, .padding = padding });
    const last = try journal.append(io, @intCast(count), .{ .value = 1, .padding = padding });
    const elapsed = since(io, started);
    try rate("append-deferred", count, elapsed);
    try check("append-deferred", "last", last.raw());
    // `reconcile` on a healthy journal: the tail rebuilt from the disk.
    const rounds: usize = if (smoke) 1 else 100;
    const reconcile_started = now(io);
    for (0..rounds) |_| if (try journal.reconcile(io) != chronicle.Seq.fromRaw(count)) return error.WrongSequence;
    try rate("reconcile", rounds, since(io, reconcile_started));
}

/// Named readers: `tailer`, `commit` (a durable cursor), `readers`,
/// `minCursor` and `Tailer.replay`.
fn tailers(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(journal, io, 10_000);
    const names = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9" };
    const commits: usize = if (smoke) 1 else 20;
    var committed: u64 = 0;
    var commit_ns: u64 = 0;
    for (names, 0..) |name, k| {
        const t = try journal.tailer(io, name);
        defer t.deinit();
        for (0..commits) |c| {
            const seq: u64 = 100 * (k + 1) + c;
            const started = now(io);
            try t.commit(io, chronicle.Seq.fromRaw(seq));
            commit_ns += since(io, started);
            committed += 1;
        }
    }
    try rate("tailer-commit", committed, commit_ns);
    const rounds: usize = if (smoke) 1 else 1000;
    var listed: u64 = 0;
    const list_started = now(io);
    for (0..rounds) |_| {
        const list = try journal.readers(gpa, io);
        listed += list.items().len;
        list.deinit();
    }
    try rate("readers", rounds, since(io, list_started));
    var lowest: u64 = 0;
    const min_started = now(io);
    for (0..rounds) |_| lowest += ((try journal.minCursor(io)) orelse return error.NoCursor).raw();
    try rate("min-cursor", rounds, since(io, min_started));
    var replayed: u64 = 0;
    const replay_started = now(io);
    {
        const t = try journal.tailer(io, "r0");
        defer t.deinit();
        const walk = try t.replay(io);
        defer walk.deinit(io);
        while (try walk.next(io)) |_| replayed += 1;
    }
    try rate("tailer-replay", replayed, since(io, replay_started));
    try check("tailer", "listed", listed);
    try check("tailer", "lowest", lowest);
    try check("tailer", "replayed", replayed);
}

/// `snapshot` of 1 MiB of state, then `openWithSnapshot`.
fn snapshots(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    {
        const journal = try J.open(gpa, io, scratch, .{ .sync = .never });
        defer journal.deinit(io);
        try fill(journal, io, 10_000);
        const state = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(state);
        @memset(state, 's');
        const rounds: usize = if (smoke) 1 else 20;
        const started = now(io);
        for (0..rounds) |_| try journal.snapshot(io, state);
        try rate("snapshot", rounds, since(io, started));
    }
    const rounds: usize = if (smoke) 1 else 20;
    var seq: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const opened = try J.openWithSnapshot(gpa, io, scratch, .{ .sync = .never });
        defer opened.journal.deinit(io);
        const taken = opened.snapshot orelse return error.NoSnapshot;
        seq += taken.seq.raw();
        taken.deinit();
    }
    try rate("open-with-snapshot", rounds, since(io, started));
    try check("snapshot", "seq", seq);
}

/// Retention on a fresh 200,000-record journal each: `dropSegmentsBefore`,
/// `truncateAfter`, `compact`. Filled without syncs, cut under `.always`.
fn retention(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const count: usize = if (smoke) 20 else 200_000;
    const half: u64 = count / 2;
    const three_quarters: u64 = count * 3 / 4;
    const segment: u64 = if (smoke) 1024 else 8 * 1024 * 1024;
    const Op = enum { drop, truncate, compact };
    inline for (.{ Op.drop, Op.truncate, Op.compact }, .{ "drop-before", "truncate-after", "compact" }) |op, work| {
        const path = try join(gpa, scratch, work);
        defer gpa.free(path);
        Io.Dir.cwd().deleteTree(io, path) catch {};
        {
            const filling = try J.open(gpa, io, path, .{ .sync = .never, .max_segment_bytes = chronicle.Bytes.fromRaw(segment) });
            defer filling.deinit(io);
            try fill(filling, io, count);
        }
        const journal = try J.open(gpa, io, path, .{ .sync = .always, .max_segment_bytes = chronicle.Bytes.fromRaw(segment) });
        defer journal.deinit(io);
        const started = now(io);
        switch (op) {
            .drop => _ = try journal.dropSegmentsBefore(io, .fromRaw(half)),
            .truncate => try journal.truncateAfter(io, .fromRaw(three_quarters)),
            .compact => try journal.compact(io, .fromRaw(half)),
        }
        const elapsed = since(io, started);
        try row(work, "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
        try check(work, "last", (try journal.lastSeq(io)).raw());
        // Where whole segments are dropped, the oldest left depends on where
        // segments end, which depends on the encoding: it is only bounded.
        const oldest = try journal.oldestSeq(io);
        try check(work, if (op == .drop) "oldest_after_drop" else "oldest", if (op == .drop) @intFromBool(oldest.compare(.fromRaw(half)) != .gt) else oldest.raw());
    }
}

/// `backup` of the prepared journal into a fresh directory.
fn backup(io: Io, gpa: std.mem.Allocator, data: []const u8, dest: []const u8) !void {
    const journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    Io.Dir.cwd().deleteTree(io, dest) catch {};
    const started = now(io);
    const records = try journal.backup(io, dest);
    const elapsed = since(io, started);
    try row("backup", "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
    // What is checked is that every segment byte arrived.
    try check("backup", "segments_complete", @intFromBool(try treeBytes(io, dest) == try treeBytes(io, data)));
    try check("backup-records", "records", records.raw());
    Io.Dir.cwd().deleteTree(io, dest) catch {};
}

/// The bytes of the segment files under `path`.
fn treeBytes(io: Io, path: []const u8) !u64 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var total: u64 = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".log")) continue;
        total += (try dir.statFile(io, entry.name, .{})).size;
    }
    return total;
}

/// The floor for `backup`: the segment and index files copied byte for byte
/// through a 1 MiB buffer, each copy and the directory synced as `backup`
/// syncs them (`F_FULLFSYNC` on macOS). `cp`, which clones on APFS, would
/// copy no bytes at all.
fn backupCopy(io: Io, data: []const u8, dest: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, dest) catch {};
    var buffer: [1 << 20]u8 = undefined;
    const started = now(io);
    var from = try Io.Dir.cwd().openDir(io, data, .{ .iterate = true });
    defer from.close(io);
    try Io.Dir.cwd().createDirPath(io, dest);
    var to = try Io.Dir.cwd().openDir(io, dest, .{});
    defer to.close(io);
    var it = from.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log") and !std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const source = try from.openFile(io, entry.name, .{});
        defer source.close(io);
        const copy = try to.createFile(io, entry.name, .{});
        defer copy.close(io);
        var offset: u64 = 0;
        while (true) {
            const n = try source.readPositionalAll(io, &buffer, offset);
            if (n == 0) break;
            try copy.writePositionalAll(io, buffer[0..n], offset);
            offset += n;
            if (n < buffer.len) break;
        }
        _ = try airlock.syncFile(io, copy, .{ .level = .full });
    }
    _ = try airlock.syncDir(io, to, .{ .level = .full });
    const elapsed = since(io, started);
    try row("backup", "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
    try check("backup", "segments_complete", @intFromBool(try treeBytes(io, dest) == try treeBytes(io, data)));
    Io.Dir.cwd().deleteTree(io, dest) catch {};
}

/// `finish` and `deinit` after one durable append: flush, sync, seal,
/// unlock.
fn finish(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const rounds: usize = if (smoke) 1 else 100;
    var total: u64 = 0;
    for (0..rounds) |i| {
        const journal = try J.open(gpa, io, scratch, .{ .sync = .always });
        _ = journal.append(io, @intCast(i + 1), .{ .value = 1, .padding = padding }) catch |err| {
            journal.deinit(io);
            return err;
        };
        const started = now(io);
        const finished = journal.finish(io);
        journal.deinit(io);
        try finished;
        total += since(io, started);
    }
    try rate("finish", rounds, total);
}
