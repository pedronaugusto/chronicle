//! Writes the journals beside this file, with chronicle bde5a26: a build
//! with a module `chronicle` at that commit, a module `strand` for its
//! `Raw` (28e76dc, what tycho carried), and `values.zig` from here.
//!
//!   generate <dir> <raw-dir>

const std = @import("std");
const chronicle = @import("chronicle");
const strand = @import("strand");
const values = @import("values.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const dir = args.next() orelse return error.MissingDirectory;
    const raw_dir = args.next() orelse return error.MissingDirectory;

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var journal = try chronicle.Journal(values.Event).open(init.gpa, io, dir, .{
        .max_segment_bytes = values.max_segment_bytes,
        .sync = .never,
    });
    defer journal.deinit(io);
    var prng = values.generator();
    for (0..values.count) |i| {
        _ = try journal.append(io, values.at(i), try values.event(arena.allocator(), prng.random(), i));
    }

    var raws = try chronicle.Journal(strand.Raw).open(init.gpa, io, raw_dir, .{
        .max_segment_bytes = values.max_segment_bytes,
        .sync = .never,
    });
    defer raws.deinit(io);
    for (0..values.raw_count) |i| {
        _ = try raws.append(io, values.at(i), .{ .bytes = try values.raw(arena.allocator(), prng.random(), i) });
    }
}
