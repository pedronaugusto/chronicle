//! The journal's writer and its readers in every order, inside a shakedown
//! `Sim` with airlock's calls routed onto its disk: `explore` runs each
//! scenario once for every schedule within two preemptions, a spurious wake
//! included, so what holds here holds for every interleaving of those steps,
//! not for the ones a thread scheduler happened to pick.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const chronicle = @import("chronicle.zig");
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const Seq = chronicle.Seq;

const Event = union(enum) {
    created: struct { id: u32 },
};

const Journal = chronicle.Journal(Event);

const os = builtin.target.os.tag;
/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

/// The records the writer appends.
const appended = 2;

/// A writer appends `appended` records while a reader waits past what it has
/// seen and replays each time it is woken: the reader sees every record, in
/// order and whole, and is never left waiting on one that arrived.
fn tail(io: Io) !void {
    const h = try seam.Seam.create(testing.allocator, io, .{ .trace = .off });
    defer h.destroy();
    const hooked = h.io();
    const journal = try Journal.open(testing.allocator, hooked, "log", .{ .sync = .never });
    defer journal.deinit(hooked);
    const Reader = struct {
        fn run(inner: Io, j: *Journal) !void {
            var seen: u64 = 0;
            while (seen < appended) {
                const newest = (try j.waitPast(inner, Seq.fromRaw(seen))).raw();
                if (newest <= seen) return error.WokenWithNothing;
                const walk = try j.replay(inner, Seq.fromRaw(seen));
                defer walk.deinit(inner);
                while (try walk.next(inner)) |record| {
                    const seq = record.seq.raw();
                    if (seq != seen + 1) return error.RecordsOutOfOrder;
                    if (record.event.created.id != seq) return error.RecordTorn;
                    seen = seq;
                }
                if (seen < newest) return error.RecordsMissing;
            }
        }
    };
    var reader = try hooked.concurrent(Reader.run, .{ hooked, journal });
    defer reader.cancel(hooked) catch |err| {
        // Cancellation joins the task; its error was checked by await.
        std.log.debug("task cleanup: {t}", .{err});
    };
    for (1..appended + 1) |seq| _ = try journal.append(hooked, @intCast(seq), .{ .created = .{ .id = @intCast(seq) } });
    try reader.await(hooked);
}

fn body(_: void, c: *shakedown.Case) anyerror!void {
    const sim = try c.sim(.{ .fs = .{ .names = names }, .executor = .threads });
    switch (sim.run(tail, .{sim.io()})) {
        .finished => {},
        .failed => |err| return err,
        else => return error.Unfinished,
    }
}

test "a reader waiting past what it has seen meets the writer in every order within two preemptions" {
    const searched = try shakedown.explore(testing.allocator, {}, body, .{ .spurious_wakes = 1 });
    try testing.expect(searched.complete);
    // The writer and the reader take turns: one schedule would prove nothing.
    try testing.expect(searched.runs > 1);
}
