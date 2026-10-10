//! Every crash of the journal's writes, inside a shakedown `Sim`: airlock's
//! syncs and renames routed onto its simulated disk, a power loss at every
//! step of a run, and every state the disk could come back in. After each,
//! a writer opens the journal as a program restarting would, and the
//! journal is checked for what it promises: its records are a prefix of
//! those appended, each whole and in its place; every append that returned
//! under `Sync.always` is among them; a compaction or a truncation that
//! returned holds, and one cut short leaves the journal whole either way.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const Seam = seam.Seam;
const Seq = chronicle.Seq;
const Records = chronicle.Records;
const Bytes = chronicle.Bytes;

const os = builtin.target.os.tag;

const Event = union(enum) {
    created: struct { id: u32, name: []const u8 },
};

const Journal = chronicle.Journal(Event);

/// The records a run appends.
const appended = 7;

const Kind = enum {
    /// One record at a time, the segments rotating every three.
    appends,
    /// Three records in one group commit, then the rest one at a time.
    group,
    /// Every record, then a compaction keeping those after the fourth.
    compact,
    /// Every record, then a truncation after the third.
    truncate,
};

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

fn options() Journal.Options {
    return .{
        .sync = .always,
        .max_segment_records = Records.fromRaw(3),
        .max_segment_bytes = Bytes.fromRaw(1 << 20),
        .write_buffer_size = Bytes.fromRaw(4096),
        .read_buffer_size = Bytes.fromRaw(4096),
    };
}

fn event(seq: u64) Event {
    return .{ .created = .{ .id = @intCast(seq), .name = "n" } };
}

const Operation = struct {
    kind: Kind,
    h: ?*Seam = null,
    /// What a run allocates: a crash abandons its tasks with their defers
    /// unrun, so what the journal held is given back here.
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    /// The appends that returned before the crash.
    acknowledged: u64 = 0,
    /// Whether the compaction or the truncation returned.
    finished: bool = false,

    pub fn setUp(s: *Operation, sim: *shakedown.Sim) !void {
        s.h = try Seam.create(testing.allocator, sim.io(), .{ .trace = .off });
        s.arena = .init(testing.allocator);
        s.acknowledged = 0;
        s.finished = false;
    }

    pub fn tearDown(s: *Operation) void {
        if (s.h) |h| h.destroy();
        s.h = null;
        s.arena.deinit();
    }

    pub fn run(s: *Operation, base: Io) !void {
        _ = base;
        const io = s.h.?.io();
        const journal = try Journal.open(s.arena.allocator(), io, "log", options());
        defer journal.deinit(io);
        var next: u64 = 1;
        if (s.kind == .group) {
            var entries: [3]Journal.Entry = undefined;
            for (&entries, 1..) |*entry, seq| entry.* = .{ .at = @intCast(seq), .event = event(seq) };
            _ = try journal.appendAll(io, &entries, .group);
            next = 4;
            s.acknowledged = 3;
        }
        while (next <= appended) : (next += 1) {
            _ = try journal.append(io, @intCast(next), event(next));
            s.acknowledged = next;
        }
        switch (s.kind) {
            .appends, .group => {},
            .compact => try journal.compact(io, Seq.fromRaw(4)),
            .truncate => try journal.truncateAfter(io, Seq.fromRaw(3)),
        }
        s.finished = true;
    }

    /// A program restarting: a writer opens the journal, which repairs what
    /// the crash left and finishes what it had begun.
    pub fn recover(s: *Operation, io: Io) !void {
        _ = s;
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const journal = try Journal.open(testing.allocator, h.io(), "log", options());
        journal.deinit(h.io());
    }

    pub fn check(s: *Operation, io: Io) !void {
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const hooked = h.io();
        const journal = try Journal.open(testing.allocator, hooked, "log", .{ .access = .read, .verify = .full });
        defer journal.deinit(hooked);
        const last = (try journal.lastSeq(hooked)).raw();
        // Nothing the run did not append, and nothing it was told is
        // durable lost.
        if (last > appended) return error.RecordFromNowhere;
        switch (s.kind) {
            // Cut short, a truncation leaves a prefix of what it was cutting,
            // never less than it keeps; `truncateAfter` again finishes it.
            .truncate => if (s.finished) {
                if (last != 3) return error.TruncationLost;
            } else if (last < @min(3, s.acknowledged)) return error.AcknowledgedLost,
            else => if (last < s.acknowledged) return error.AcknowledgedLost,
        }
        // The records there are are those appended, in order, each whole.
        const walk = try journal.replay(hooked, Seq.fromRaw(0));
        defer walk.deinit(hooked);
        var expected: ?u64 = null;
        while (try walk.next(hooked)) |record| {
            const seq = record.seq.raw();
            if (expected) |e| {
                if (seq != e) return error.RecordsOutOfOrder;
            } else {
                // A compaction drops what it was told to, once it returned
                // and perhaps before; nothing else goes.
                const first_ok = switch (s.kind) {
                    .compact => if (s.finished) seq == 5 else seq == 1 or seq == 5,
                    else => seq == 1,
                };
                if (!first_ok) return error.HistoryLost;
            }
            try testing.expectEqual(@as(u32, @intCast(seq)), record.event.created.id);
            try testing.expectEqual(@as(i64, @intCast(seq)), record.at);
            expected = seq + 1;
        }
        if (last != 0 and expected != last + 1) return error.RecordsMissing;
    }
};

fn everyCrash(kind: Kind) !void {
    var ctx: Operation = .{ .kind = kind };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyCrash(testing.allocator, &ctx, .{
        .sim = .{ .fs = .{ .names = names }, .watchdog = null },
        .max_states = 512,
        .max_steps = 1_000_000,
        .diagnostics = &report,
    });
    const done = result catch |err| {
        if (report.failure) |f| {
            std.debug.print("every crash {t}: {t} at {any}\n{s}\n", .{ kind, f.err, f.injected, f.trace });
        }
        return err;
    };
    // Every state of every point was tried.
    try testing.expectEqual(@as(u64, 0), done.bounded);
}

test "every crash: appends one at a time across segments" {
    try everyCrash(.appends);
}

test "every crash: a group commit, then appends" {
    try everyCrash(.group);
}

test "every crash: a compaction" {
    try everyCrash(.compact);
}

test "every crash: a truncation" {
    try everyCrash(.truncate);
}
