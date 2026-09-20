//! Holds or mutates a journal in a second process, so the suite can prove
//! process-locking, hot backup and recovery from an actual killed writer.
//!
//! It opens the journal named by its first argument and writes `locked` and a
//! newline to standard output to say the lock is held. Given a second
//! argument, it then appends that many records, writing `appending` and a
//! newline once enough of them are down that the next one is certainly being
//! written while the reader looks. With `crash` and a seed it instead loops
//! over every mutating API until the test kills it. The ordinary modes end by
//! blocking until standard input is closed — which is how the test lets them
//! go. A lock is released by the operating system when the process ends.
//!
//! `zig build test` builds this and hands the test binary its path in
//! `CHRONICLE_LOCK_HELPER`; the tests that need it are skipped without that.

const std = @import("std");
const chronicle = @import("chronicle");

/// The helper writes nothing but pings, so one arm is enough. The tests that
/// read what it wrote instantiate a journal over this same type.
pub const Event = union(enum) { ping: u32 };

/// How many records go down before `appending` is reported, so that a reader
/// which waits for that line is looking at a log that is still growing.
const announce_after = 200;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingJournalPath;
    const crash_mode = args.len > 2 and std.mem.eql(u8, args[2], "crash");
    const appends: u64 = if (args.len > 2 and !crash_mode)
        try std.fmt.parseInt(u64, args[2], 10)
    else
        0;

    // No tail: this process has no business holding records in memory, and no
    // fsync, because what is being proved here is about locking and about what
    // a second process can see, not about power cuts.
    var journal = try chronicle.Journal(Event).open(init.gpa, io, args[1], .{
        .tail_records = 0,
        .sync = .never,
        .max_segment_records = if (crash_mode) 4 else null,
        .preallocate_bytes = if (crash_mode) 512 else 0,
    });
    defer journal.deinit(io);

    var out_buffer: [64]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try out.interface.writeAll("locked\n");
    try out.interface.flush();

    if (crash_mode) {
        const seed = if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 0;
        var random: std.Random.DefaultPrng = .init(seed);
        const backup_path = try std.fmt.allocPrint(init.gpa, "{s}.backup", .{args[1]});
        defer init.gpa.free(backup_path);
        try out.interface.writeAll("mutating\n");
        try out.interface.flush();

        var step: u64 = 0;
        while (true) : (step +%= 1) {
            const newest = try journal.lastSeq(io);
            const oldest = journal.oldestSeq();
            switch (random.random().uintLessThan(u8, 7)) {
                0 => _ = try journal.append(io, @intCast(step % std.math.maxInt(i64)), .{ .ping = @intCast(step % 1000) }),
                1 => {
                    const batch = [_]chronicle.Journal(Event).Entry{
                        .{ .at = @intCast(step % std.math.maxInt(i64)), .event = .{ .ping = 1 } },
                        .{ .at = @intCast(step % std.math.maxInt(i64)), .event = .{ .ping = 2 } },
                        .{ .at = @intCast(step % std.math.maxInt(i64)), .event = .{ .ping = 3 } },
                    };
                    _ = try journal.appendAll(io, &batch);
                },
                2 => try journal.compact(io, random.random().intRangeAtMost(u64, 0, newest)),
                3 => journal.truncateAfter(
                    io,
                    random.random().intRangeAtMost(u64, oldest -| 1, newest),
                ) catch |err| switch (err) {
                    error.SeqTooOld => {},
                    else => return err,
                },
                4 => _ = try journal.dropSegmentsBefore(
                    io,
                    random.random().intRangeAtMost(u64, 0, newest),
                ),
                5 => _ = try journal.backup(io, backup_path),
                else => try journal.snapshot(io, "a fold"),
            }
        }
    }

    var written: u64 = 0;
    while (written < appends) : (written += 1) {
        _ = try journal.append(io, @intCast(written), .{ .ping = @intCast(written % 1000) });
        if (written + 1 == announce_after) {
            try out.interface.writeAll("appending\n");
            try out.interface.flush();
        }
    }

    var in_buffer: [64]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    _ = in.interface.discardRemaining() catch {};
}
