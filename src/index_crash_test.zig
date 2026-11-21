//! Every crash of a journal's index writes, inside a shakedown `Sim`: a
//! power loss at every step of appends whose seals write index files, of a
//! cut inside a sealed segment followed by appends that put other records in
//! its place and seal it again, and of `buildIndexes` over a journal written
//! before its indexes were declared, with up to 256 of the states the disk
//! could come back in at each step (see `everyCrash`). After each,
//! a writer opens the journal as a program restarting would, and every read
//! by key equals a full replay filtered by the key, before and after
//! `buildIndexes` runs to its end: a crash costs a rebuild, never a wrong
//! answer.
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
const index = chronicle.index;

const Event = union(enum) {
    created: struct { id: u32, account: u32 },

    pub const chronicle = .{ .indexes = &.{
        index("account", 1, .exact, accountOf),
        index("id", 1, .ordered, idOf),
    } };

    fn accountOf(e: Event) ?u32 {
        return e.created.account;
    }
    fn idOf(e: Event) ?u32 {
        return e.created.id;
    }
};

/// `Event` as a journal without indexes writes it.
const Plain = union(enum) {
    created: struct { id: u32, account: u32 },
};

const Journal = chronicle.Journal(Event);

const Kind = enum {
    /// Two records, a segment each: the second seals segment 1.
    seals,
    /// Three records, two a segment, so the third seals segment 1; a cut
    /// after the first; then two records, the first in the cut one's place
    /// with another account, the second sealing segment 1 again.
    cut,
    /// Two records written without indexes, a segment each, then
    /// `buildIndexes` to its end.
    build,

    fn records(kind: Kind) u64 {
        return if (kind == .cut) 2 else 1;
    }
};

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

/// Few records a segment, so that few appends seal one: the sweep's crash
/// points are mostly an append's, which the journal's own crash tests cover.
fn options(records: u64) Journal.Options {
    return .{
        .sync = .always,
        .max_segment_records = Records.fromRaw(records),
        .max_segment_bytes = Bytes.fromRaw(1 << 20),
        .write_buffer_size = Bytes.fromRaw(4096),
        .read_buffer_size = Bytes.fromRaw(4096),
    };
}

fn event(id: u64, account: u32) Event {
    return .{ .created = .{ .id = @intCast(id), .account = account } };
}

pub const Operation = struct {
    kind: Kind,
    h: ?*Seam = null,
    /// What a run allocates: a crash abandons its tasks with their defers
    /// unrun, so what the journal held is given back here.
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    pub fn setUp(s: *Operation, sim: *shakedown.Sim) !void {
        s.h = try Seam.create(testing.allocator, sim.io(), .{ .trace = .off });
        s.arena = .init(testing.allocator);
    }

    pub fn tearDown(s: *Operation) void {
        if (s.h) |h| h.destroy();
        s.h = null;
        s.arena.deinit();
    }

    pub fn run(s: *Operation, base: Io) !void {
        _ = base;
        const io = s.h.?.io();
        const gpa = s.arena.allocator();
        const opened = options(s.kind.records());
        switch (s.kind) {
            .seals => {
                const journal = try Journal.open(gpa, io, "log", opened);
                defer journal.deinit(io);
                for (1..3) |id| _ = try journal.append(io, .fromRaw(0), event(id, @intCast(id % 2)));
            },
            .cut => {
                const journal = try Journal.open(gpa, io, "log", opened);
                defer journal.deinit(io);
                for (1..4) |id| _ = try journal.append(io, .fromRaw(0), event(id, 1));
                try journal.truncateAfter(io, Seq.fromRaw(1));
                for (2..4) |id| _ = try journal.append(io, .fromRaw(0), event(id, 2));
            },
            .build => {
                {
                    const plain = try chronicle.Journal(Plain).open(gpa, io, "log", .{ .sync = .always, .max_segment_records = Records.fromRaw(1) });
                    defer plain.deinit(io);
                    for (1..3) |id| _ = try plain.append(io, .fromRaw(0), .{ .created = .{ .id = @intCast(id), .account = @intCast(id % 2) } });
                }
                const journal = try Journal.open(gpa, io, "log", opened);
                defer journal.deinit(io);
                while (try journal.buildIndexes(io)) |_| {}
            },
        }
    }

    /// A program restarting: a writer opens the journal, which repairs what
    /// the crash left.
    pub fn recover(s: *Operation, io: Io) !void {
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const journal = Journal.open(testing.allocator, h.io(), "log", options(s.kind.records())) catch |err| switch (err) {
            // A crash before the first segment was made leaves nothing to open.
            error.FileNotFound => return,
            else => |e| return e,
        };
        journal.deinit(h.io());
    }

    pub fn check(s: *Operation, io: Io) !void {
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        const hooked = h.io();
        const journal = Journal.open(testing.allocator, hooked, "log", options(s.kind.records())) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer journal.deinit(hooked);
        try readsAgree(journal, hooked);
        while (try journal.buildIndexes(hooked)) |_| {}
        try readsAgree(journal, hooked);
        const status = try journal.indexStatus(hooked);
        for (status.indexes) |each| if (each.missing != 0) return error.IndexMissingAfterBuild;
    }
};

/// Every account's read and a range of ids equal a replay filtered by them.
fn readsAgree(journal: *Journal, io: Io) !void {
    for (0..3) |account| {
        try agree(journal, io, .{ .account = @intCast(account) });
    }
    try agree(journal, io, .{ .ids = .{ .lo = 2, .hi = 5 } });
}

const Query = union(enum) {
    account: u32,
    ids: struct { lo: u32, hi: u32 },

    fn holds(q: Query, e: Event) bool {
        return switch (q) {
            .account => |a| e.created.account == a,
            .ids => |r| r.lo <= e.created.id and e.created.id <= r.hi,
        };
    }
};

fn agree(journal: *Journal, io: Io, q: Query) !void {
    var want: [16]u64 = undefined;
    var wanted: usize = 0;
    {
        const walk = try journal.replay(io, Seq.fromRaw(0));
        defer walk.deinit(io);
        while (try walk.next(io)) |r| if (q.holds(r.event)) {
            want[wanted] = r.seq.raw();
            wanted += 1;
        };
    }
    const walk = switch (q) {
        .account => |a| try journal.readIndexed(io, "account", a, .after(Seq.fromRaw(0))),
        .ids => |r| try journal.readRange(io, "id", r.lo, r.hi, .after(Seq.fromRaw(0))),
    };
    defer walk.deinit(io);
    var got: usize = 0;
    while (try walk.next(io)) |r| {
        if (got == wanted or !r.seq.eql(.fromRaw(want[got]))) return error.ReadByKeyDisagrees;
        got += 1;
    }
    if (got != wanted) return error.ReadByKeyMissedRecords;
}

fn everyCrash(kind: Kind) !void {
    var ctx: Operation = .{ .kind = kind };
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyCrash(testing.allocator, &ctx, .{
        .sim = .{ .fs = .{ .names = names }, .watchdog = null },
        // Index files are written with no sync, so a crash point after one
        // can leave more disk images (each unsynced byte there or not) than a
        // sweep can recover within the runner's watchdog: these try the first
        // 256 of each point, which the seal sweep's 117 points pass at 23.
        .max_states = 256,
        .max_steps = 1_000_000,
        .diagnostics = &report,
    });
    const done = result catch |err| {
        if (report.failure) |f| {
            std.debug.print("every crash {t}: {t} at {any}\n{s}\n", .{ kind, f.err, f.injected, f.trace });
        }
        return err;
    };
    // Every point was run and recovered from at least once.
    try testing.expect(done.runs > 0);
}

test "every crash of appends whose seals write index files leaves reads by key right" {
    try everyCrash(.seals);
}

test "every crash of a cut inside a sealed segment, and the appends that seal it again, leaves reads by key right" {
    try everyCrash(.cut);
}

test "every crash of buildIndexes leaves reads by key right, and a build after it finishes the files" {
    try everyCrash(.build);
}
