//! The public operations the journal jobs do not time, one mode each,
//! against the snapshot this program is built from.
//!
//!   cover-bench MODE [DATA] [SCRATCH]
//!
//! DATA is a prepared million-record journal, opened for reading only.
//! SCRATCH is a directory this invocation owns. Every mode prints timing rows
//! and `checksum` rows; the checksums are what every other side of the same
//! job computes, and the harness compares them.
const std = @import("std");
const chronicle = @import("chronicle");
const strand = @import("strand");
const ref = @import("compat.zig").ref;
const smoke = @import("bench_options").smoke;
const Io = std.Io;

const Event = struct { value: u64, padding: []const u8 };
const J = chronicle.Journal(Event);
const padding = "x" ** 172;
const side = "chronicle";

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
    try out.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ side, workload, metric, value, unit });
}
fn rate(workload: []const u8, items: u64, elapsed: u64) !void {
    const n: f64 = @floatFromInt(@max(items, 1));
    const t: f64 = @floatFromInt(elapsed);
    try row(workload, "items", n * 1e9 / t, "items/s");
    try row(workload, "per_item", t / n, "ns");
}
fn check(workload: []const u8, metric: []const u8, value: u64) !void {
    try out.print("{s}\t{s}\t{s}\t{d}\tchecksum\n", .{ side, workload, metric, value });
}

fn options(sync: chronicle.Sync, access: chronicle.Access) J.Options {
    return .{ .access = access, .sync = sync, .tail_records = 0, .tail_bytes = 0, .max_segment_bytes = 8 * 1024 * 1024, .verify_round_trip = false };
}

/// The same pseudo-random cursors the Go side draws: an LCG, high bits.
const Cursors = struct {
    state: u64 = 0x2545F4914F6CDD1D,
    fn next(c: *Cursors, below: u64) u64 {
        c.state = c.state *% 6364136223846793005 +% 1442695040888963407;
        return (c.state >> 33) % below;
    }
};

fn join(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ dir, name });
}

fn fill(journal: *J, io: Io, count: usize) !void {
    var entries: [1000]J.Entry = undefined;
    var offset: usize = 0;
    while (offset < count) {
        const n = @min(entries.len, count - offset);
        for (entries[0..n], 0..) |*entry, i| entry.* = .{ .at = @intCast(offset + i + 1), .event = .{ .value = 1, .padding = padding } };
        _ = try journal.appendAll(io, entries[0..n]);
        offset += n;
    }
}

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };
    out_writer = Io.File.stdout().writer(io, &out_buffer);
    out = &out_writer.interface;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    const Mode = enum { checksum, @"checksum-std", verify, @"reopen-full", seek, @"seq-at", @"subscribe-from", @"copy-since", refresh, @"wait-past", deferred, tailer, snapshot, retention, backup, @"backup-copy", close };
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.Usage;
    switch (mode) {
        .checksum => try checksums(io, gpa, false),
        .@"checksum-std" => try checksums(io, gpa, true),
        .verify => try verify(io, gpa, args[2]),
        .@"reopen-full" => try reopenFull(io, gpa, args[2], try std.fmt.parseInt(usize, args[3], 10)),
        .seek => try seek(io, gpa, args[2]),
        .@"seq-at" => try seqAt(io, gpa, args[2]),
        .@"subscribe-from" => try subscribeFrom(io, gpa, args[2]),
        .@"copy-since" => if (comptime @hasDecl(J, "copySince")) try copySince(io, gpa, args[2]) else return error.Unavailable,
        .refresh => try refresh(io, gpa, args[2]),
        .@"wait-past" => try waitPast(io, gpa, args[2]),
        .deferred => try deferred(io, gpa, args[2]),
        .tailer => try tailers(io, gpa, args[2]),
        .snapshot => try snapshots(io, gpa, args[2]),
        .retention => try retention(io, gpa, args[2]),
        .backup => try backup(io, gpa, args[2], args[3]),
        .@"backup-copy" => try backupCopy(io, args[2], args[3]),
        .close => try close(io, gpa, args[2]),
    }
    try out.flush();
}

/// The record checksum over buffers of three sizes, 256 MiB of each.
fn checksums(io: Io, gpa: std.mem.Allocator, comptime std_table: bool) !void {
    const total: usize = if (smoke) 64 * 1024 else 256 << 20;
    const bytes = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    const who = if (std_table) "zig-std" else side;
    inline for (.{ 64, 1024, 64 * 1024 }, .{ "checksum-64", "checksum-1k", "checksum-64k" }) |len, work| {
        var sum: u64 = 0;
        const rounds = total / len;
        const started = now(io);
        for (0..rounds) |i| {
            const piece = bytes[(i * 64) % (bytes.len - len + 1) ..][0..len];
            sum += if (std_table) std.hash.crc.Crc32Iscsi.hash(piece) else chronicle.checksum(piece);
        }
        const elapsed = since(io, started);
        try out.print("{s}\t{s}\tbytes\t{d:.6}\tMB/s\n", .{ who, work, @as(f64, @floatFromInt(rounds * len)) * 1e3 / @as(f64, @floatFromInt(elapsed)) });
        try out.print("{s}\t{s}\tsum\t{d}\tchecksum\n", .{ who, work, sum });
    }
}

/// `verify` over the prepared journal: every record read and checked.
fn verify(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    var journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const started = now(io);
    const records = try journal.verify(io);
    const elapsed = since(io, started);
    try rate("verify", records, elapsed);
    try check("verify", "records", records);
}

/// `open` with `verify = .full`: the work a recovery that reads every record
/// does, which is what OkayWAL's open does.
fn reopenFull(io: Io, gpa: std.mem.Allocator, data: []const u8, repetitions: usize) !void {
    var total: u64 = 0;
    var last: u64 = 0;
    for (0..repetitions) |_| {
        var o = options(.never, .read);
        o.verify = .full;
        const started = now(io);
        var journal = try J.open(gpa, io, data, o);
        total += since(io, started);
        last = try journal.lastSeq(io);
        journal.deinit(io);
    }
    try row("clean_reopen", "elapsed", @as(f64, @floatFromInt(total)) / 1e6 / @as(f64, @floatFromInt(repetitions)), "ms");
    try check("clean_reopen", "last", last);
}

/// `replay(cursor)` and one `next`, at 2,000 pseudo-random cursors.
fn seek(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    var journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = try journal.lastSeq(io);
    const rounds: usize = if (smoke) 1 else 2_000;
    var cursors: Cursors = .{};
    var sum: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const cursor = cursors.next(count);
        var walk = try journal.replay(io, cursor);
        defer ref(&walk).deinit(io);
        const record = (try ref(&walk).next(io)) orelse return error.NoRecord;
        if (record.seq != cursor + 1) return error.WrongSequence;
        sum += record.seq;
    }
    const elapsed = since(io, started);
    try rate("seek", rounds, elapsed);
    try check("seek", "sum", sum);
}

/// `seqAtOrAfter` at 10,000 pseudo-random times (`at` is the record's number).
fn seqAt(io: Io, gpa: std.mem.Allocator, data: []const u8) !void {
    var journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = try journal.lastSeq(io);
    const rounds: usize = if (smoke) 1 else 10_000;
    var cursors: Cursors = .{};
    var sum: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const at = cursors.next(count) + 1;
        sum += (try journal.seqAtOrAfter(io, @intCast(at))) orelse return error.NoRecord;
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
    var journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    const count = try journal.lastSeq(io);
    const from = count - count / 10;
    {
        var one: Fold = .{};
        const started = now(io);
        try journal.subscribeFrom(io, one.sink(), from);
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
        try journal.subscribeAllFrom(io, &sinks, from);
        const elapsed = since(io, started);
        var seen: u64 = 0;
        for (five) |fold| seen += fold.seen;
        try rate("subscribe-all-from", count - from, elapsed);
        try check("subscribe-all-from", "seen", seen);
    }
}

/// `copySince` of the last hundred records, held in the tail.
fn copySince(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    var journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(ref(&journal), io, 10_000);
    const rounds: usize = if (smoke) 1 else 10_000;
    var records: u64 = 0;
    const started = now(io);
    for (0..rounds) |_| {
        const batch = try journal.copySince(gpa, io, 10_000 - 100);
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
    var writer = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer writer.deinit(io);
    try fill(ref(&writer), io, 1000);
    var reader = try J.open(gpa, io, scratch, options(.never, .read));
    defer reader.deinit(io);
    const rounds: usize = if (smoke) 1 else 1000;
    var total: u64 = 0;
    for (0..rounds) |i| {
        _ = try writer.append(io, @intCast(1001 + i), .{ .value = 1, .padding = padding });
        const started = now(io);
        try reader.refresh(io);
        total += since(io, started);
    }
    const last = try reader.lastSeq(io);
    try rate("refresh", rounds, total);
    try check("refresh", "last", last);
}

const Waiter = struct {
    sent_at: std.atomic.Value(i64) = .init(0),
    done: std.atomic.Value(u64) = .init(0),
    latency: u64 = 0,
};

fn stamp(io: Io) i64 {
    return @intCast(now(io).nanoseconds);
}

/// Wait past each new record and take it in hand: `waitPast` (which, before
/// the pin moved, handed back the records too) and then `copySince`.
fn wait(io: Io, gpa: std.mem.Allocator, journal: *J, rounds: u64, waiter: *Waiter) !void {
    var cursor: u64 = 1000;
    for (0..rounds) |i| {
        while (true) {
            const got = try journal.waitPast(io, cursor);
            const newest: u64 = if (comptime @TypeOf(got) == u64) blk: {
                const batch = try journal.copySince(gpa, io, cursor);
                defer batch.deinit();
                break :blk if (batch.records().len == 0) cursor else batch.records()[batch.records().len - 1].seq;
            } else if (got.records.len == 0) cursor else got.records[got.records.len - 1].seq;
            if (newest > cursor) {
                cursor = newest;
                break;
            }
        }
        waiter.latency += @intCast(@max(stamp(io) - waiter.sent_at.load(.acquire), 0));
        waiter.done.store(i + 1, .release);
    }
}

fn waitPast(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    var journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(ref(&journal), io, 1000);
    const rounds: u64 = if (smoke) 2 else 1000;
    var waiter: Waiter = .{};
    var task = try io.concurrent(wait, .{ io, gpa, ref(&journal), rounds, &waiter });
    for (0..rounds) |i| {
        waiter.sent_at.store(stamp(io), .release);
        _ = try journal.append(io, @intCast(1001 + i), .{ .value = 1, .padding = padding });
        while (waiter.done.load(.acquire) < i + 1) std.atomic.spinLoopHint();
    }
    try task.await(io);
    try row("wait-past", "latency", @as(f64, @floatFromInt(waiter.latency)) / @as(f64, @floatFromInt(rounds)) / 1e3, "us");
    try check("wait-past", "records", waiter.done.load(.acquire));
}

/// Under `.always`, deferred appends, then one durable append that makes
/// them durable too.
fn deferred(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const count: usize = if (smoke) 2 else 10_000;
    var journal = try J.open(gpa, io, scratch, options(.always, .write));
    defer journal.deinit(io);
    const started = now(io);
    for (0..count - 1) |i| _ = try journal.appendDeferred(io, @intCast(i + 1), .{ .value = 1, .padding = padding });
    const last = try journal.append(io, @intCast(count), .{ .value = 1, .padding = padding });
    const elapsed = since(io, started);
    try rate("append-deferred", count, elapsed);
    try check("append-deferred", "last", last);
    // `reconcile` on a healthy journal: the tail rebuilt from the disk.
    const rounds: usize = if (smoke) 1 else 100;
    const reconcile_started = now(io);
    for (0..rounds) |_| if (try journal.reconcile(io) != count) return error.WrongSequence;
    try rate("reconcile", rounds, since(io, reconcile_started));
}

/// Named readers: `tailer`, `commit` (a durable cursor), `readers`,
/// `minCursor` and `Tailer.replay`.
fn tailers(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    var journal = try J.open(gpa, io, scratch, .{ .sync = .never });
    defer journal.deinit(io);
    try fill(ref(&journal), io, 10_000);
    const names = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9" };
    const commits: usize = if (smoke) 1 else 20;
    var committed: u64 = 0;
    var commit_ns: u64 = 0;
    for (names, 0..) |name, k| {
        var t = try journal.tailer(io, name);
        defer ref(&t).deinit();
        for (0..commits) |c| {
            const seq: u64 = 100 * (k + 1) + c;
            const started = now(io);
            try ref(&t).commit(io, seq);
            commit_ns += since(io, started);
            committed += 1;
        }
    }
    try rate("tailer-commit", committed, commit_ns);
    const rounds: usize = if (smoke) 1 else 1000;
    var listed: u64 = 0;
    const list_started = now(io);
    for (0..rounds) |_| {
        var list = try journal.readers(io);
        listed += if (comptime @typeInfo(@TypeOf(list)) == .pointer) list.items().len else list.items.len;
        ref(&list).deinit();
    }
    try rate("readers", rounds, since(io, list_started));
    var lowest: u64 = 0;
    const min_started = now(io);
    for (0..rounds) |_| lowest += (try journal.minCursor(io)) orelse return error.NoCursor;
    try rate("min-cursor", rounds, since(io, min_started));
    var replayed: u64 = 0;
    const replay_started = now(io);
    {
        var t = try journal.tailer(io, "r0");
        defer ref(&t).deinit();
        var walk = try ref(&t).replay(io);
        defer ref(&walk).deinit(io);
        while (try ref(&walk).next(io)) |_| replayed += 1;
    }
    try rate("tailer-replay", replayed, since(io, replay_started));
    try check("tailer", "listed", listed);
    try check("tailer", "lowest", lowest);
    try check("tailer", "replayed", replayed);
}

/// `snapshot` of 1 MiB of state, then `openWithSnapshot`.
fn snapshots(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    {
        var journal = try J.open(gpa, io, scratch, .{ .sync = .never });
        defer journal.deinit(io);
        try fill(ref(&journal), io, 10_000);
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
        var opened = try J.openWithSnapshot(gpa, io, scratch, .{ .sync = .never });
        const taken = opened.snapshot orelse return error.NoSnapshot;
        seq += taken.seq;
        gpa.free(taken.state);
        ref(&opened.journal).deinit(io);
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
            var filling = try J.open(gpa, io, path, .{ .sync = .never, .max_segment_bytes = segment });
            defer filling.deinit(io);
            try fill(ref(&filling), io, count);
        }
        var journal = try J.open(gpa, io, path, .{ .sync = .always, .max_segment_bytes = segment });
        defer journal.deinit(io);
        const started = now(io);
        switch (op) {
            .drop => _ = try journal.dropSegmentsBefore(io, half),
            .truncate => try journal.truncateAfter(io, three_quarters),
            .compact => try journal.compact(io, half),
        }
        const elapsed = since(io, started);
        try row(work, "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
        try check(work, "last", try journal.lastSeq(io));
        // `oldestSeq` took no `io` before the pin moved. Where whole segments
        // are dropped, the oldest left depends on where segments end, which
        // differs with each revision's encoding; it is not compared.
        const oldest = if (comptime @typeInfo(@TypeOf(J.oldestSeq)).@"fn".params.len == 1) journal.oldestSeq() else try journal.oldestSeq(io);
        try check(work, if (op == .drop) "oldest_after_drop" else "oldest", if (op == .drop) @intFromBool(oldest <= half) else oldest);
    }
}

/// `backup` of the prepared journal into a fresh directory.
fn backup(io: Io, gpa: std.mem.Allocator, data: []const u8, dest: []const u8) !void {
    var journal = try J.open(gpa, io, data, options(.never, .read));
    defer journal.deinit(io);
    Io.Dir.cwd().deleteTree(io, dest) catch {};
    const started = now(io);
    const records = try journal.backup(io, dest);
    const elapsed = since(io, started);
    try row("backup", "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
    // Each side backs up its own journal (the formats differ by revision):
    // what is compared is that every segment byte arrived.
    try check("backup", "segments_complete", @intFromBool(try treeBytes(io, dest) == try treeBytes(io, data)));
    try check("backup-records", "records", records);
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
        _ = try strand.syncFile(copy, io, .all);
    }
    {
        const handle = try Io.Dir.cwd().openFile(io, dest, .{ .allow_directory = true });
        defer handle.close(io);
        _ = try strand.syncFile(handle, io, .all);
    }
    const elapsed = since(io, started);
    try row("backup", "elapsed", @as(f64, @floatFromInt(elapsed)) / 1e6, "ms");
    try check("backup", "segments_complete", @intFromBool(try treeBytes(io, dest) == try treeBytes(io, data)));
    Io.Dir.cwd().deleteTree(io, dest) catch {};
}

/// `close` after one durable append: flush, sync, unlock.
fn close(io: Io, gpa: std.mem.Allocator, scratch: []const u8) !void {
    const rounds: usize = if (smoke) 1 else 100;
    var total: u64 = 0;
    for (0..rounds) |i| {
        var journal = try J.open(gpa, io, scratch, .{ .sync = .always });
        _ = try journal.append(io, @intCast(i + 1), .{ .value = 1, .padding = padding });
        const started = now(io);
        try journal.close(io);
        total += since(io, started);
    }
    try rate("close", rounds, total);
}
