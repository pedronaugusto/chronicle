//! Copying a file's bytes without moving them through this process, where the
//! platform has a call for it.
//!
//! A backup of a sealed segment is a copy of bytes that will never change
//! again, which is the one thing filesystems are good at doing by themselves:
//! APFS clones a file by sharing its extents, and Linux hands the copy to the
//! filesystem, which does the same on XFS and btrfs and reads and writes it in
//! the kernel otherwise.
//!
//! Every call here is allowed to say no. The answer is then a byte copy, which
//! is what this package did before and what it still does on a filesystem, a
//! platform or a pair of directories that cannot share extents.
//!
//! This file is internal. `chronicle.zig` is the package.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// Darwin's whole-file clone. Not declared in `std.c`, so it is declared here.
/// `flags` is zero; there is no flag this package wants.
extern "c" fn clonefileat(
    src_dirfd: std.c.fd_t,
    src: [*:0]const u8,
    dst_dirfd: std.c.fd_t,
    dst: [*:0]const u8,
    flags: u32,
) c_int;

/// Whether this platform has anything to try.
pub const available = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .linux => true,
    else => false,
};

/// Copy the whole of `name` from `source` into `dest`, and report whether the
/// platform did it. False means nothing was written and the caller should copy
/// the bytes itself.
///
/// `dest` must not already hold `name`: Darwin's clone refuses a destination
/// that exists, and the caller removes it first.
pub fn whole(io: Io, source: Io.Dir, dest: Io.Dir, name: [:0]const u8) bool {
    if (!available) return false;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            return clonefileat(source.handle, name, dest.handle, name, 0) == 0;
        },
        .linux => {
            const from = source.openFile(io, name, .{}) catch return false;
            defer from.close(io);
            const length = from.length(io) catch return false;
            const to = dest.createFile(io, name, .{ .truncate = true }) catch return false;
            defer to.close(io);
            return range(to, from, length);
        },
        else => return false,
    }
}

/// Copy the first `length` bytes of one open file into another, from offset
/// zero, and report whether the platform did all of it.
pub fn range(to: Io.File, from: Io.File, length: u64) bool {
    if (builtin.os.tag != .linux) return false;
    var at: u64 = 0;
    while (at < length) {
        var in: i64 = @intCast(at);
        var out: i64 = @intCast(at);
        const want: usize = @intCast(length - at);
        const moved = std.os.linux.copy_file_range(from.handle, &in, to.handle, &out, want, 0);
        switch (std.posix.errno(moved)) {
            .SUCCESS => {},
            // Every one of these is "not here, not now": a filesystem that
            // will not do it, a kernel that does not have it, two files on
            // different mounts. The caller copies the bytes.
            else => return false,
        }
        if (moved == 0) return false;
        at += moved;
    }
    return true;
}
