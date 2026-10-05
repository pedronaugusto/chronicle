//! An allocating writer that remembers whether its storage failed.
//!
//! The writer interface reports WriteFailed for both allocation failure and
//! a custom stringify hook's refusal. This owner can distinguish the two by
//! observing only the allocating writer's operations. The buffer and all its
//! growth still belong to std.Io.Writer.Allocating.

const std = @import("std");
const Writer = std.Io.Writer;
const Self = @This();

output: Writer.Allocating,
allocation_failed: bool = false,

const original = Writer.Allocating.init(undefined).writer.vtable.*;
const vtable: Writer.VTable = blk: {
    var hooks = original;
    hooks.drain = drain;
    hooks.rebase = rebase;
    hooks.sendFile = sendFile;
    break :blk hooks;
};

pub fn init(output: Writer.Allocating) Self {
    var self: Self = .{ .output = output };
    self.output.writer.vtable = &vtable;
    return self;
}

pub fn diagnose(self: *const Self, err: Writer.Error) (Writer.Error || std.mem.Allocator.Error) {
    return if (self.allocation_failed) error.OutOfMemory else err;
}

fn owner(writer: *Writer) *Self {
    const output: *Writer.Allocating = @fieldParentPtr("writer", writer);
    return @fieldParentPtr("output", output);
}

fn drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    return original.drain(writer, data, splat) catch |err| {
        owner(writer).allocation_failed = true;
        return err;
    };
}

fn rebase(writer: *Writer, preserve: usize, capacity: usize) Writer.Error!void {
    return original.rebase(writer, preserve, capacity) catch |err| {
        owner(writer).allocation_failed = true;
        return err;
    };
}

fn sendFile(writer: *Writer, reader: *std.Io.File.Reader, limit: std.Io.Limit) Writer.FileError!usize {
    return original.sendFile(writer, reader, limit) catch |err| {
        if (err == error.WriteFailed) owner(writer).allocation_failed = true;
        return err;
    };
}
