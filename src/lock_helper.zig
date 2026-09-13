//! Holds a journal's write lock in a second process, so that the suite can
//! prove `error.Locked` is a real answer and not a story about one.
//!
//! It opens the journal named by its first argument, writes `locked` and a
//! newline to standard output to say the lock is held, and then blocks until
//! its standard input is closed — which is how the test lets it go. A lock is
//! released by the operating system when the process ends, so being killed is
//! also a way out.
//!
//! `zig build test` builds this and hands the test binary its path in
//! `CHRONICLE_LOCK_HELPER`; the test that needs it is skipped without that.

const std = @import("std");
const chronicle = @import("chronicle");

/// The helper never reads a record and never appends one, so one arm is enough
/// to instantiate a journal.
const Event = union(enum) { ping: u32 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingJournalPath;

    // No tail: the lock is the whole point here, and this process has no
    // business parsing records written against somebody else's event type.
    var journal = try chronicle.Journal(Event).open(init.gpa, io, args[1], .{ .tail_records = 0 });
    defer journal.deinit(io);

    var out_buffer: [64]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try out.interface.writeAll("locked\n");
    try out.interface.flush();

    var in_buffer: [64]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    _ = in.interface.discardRemaining() catch {};
}
