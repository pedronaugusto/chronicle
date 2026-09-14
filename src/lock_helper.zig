//! Holds a journal's write lock in a second process, and optionally appends to
//! it, so that the suite can prove `error.Locked` is a real answer and that a
//! backup taken beside a live writer is a real copy — neither of which one
//! process can show on its own.
//!
//! It opens the journal named by its first argument and writes `locked` and a
//! newline to standard output to say the lock is held. Given a second
//! argument, it then appends that many records, writing `appending` and a
//! newline once enough of them are down that the next one is certainly being
//! written while the reader looks. Either way it ends by blocking until its
//! standard input is closed — which is how the test lets it go. A lock is
//! released by the operating system when the process ends, so being killed is
//! also a way out.
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
    const appends: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 0;

    // No tail: this process has no business holding records in memory, and no
    // fsync, because what is being proved here is about locking and about what
    // a second process can see, not about power cuts.
    var journal = try chronicle.Journal(Event).open(init.gpa, io, args[1], .{
        .tail_records = 0,
        .sync = .never,
    });
    defer journal.deinit(io);

    var out_buffer: [64]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try out.interface.writeAll("locked\n");
    try out.interface.flush();

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
