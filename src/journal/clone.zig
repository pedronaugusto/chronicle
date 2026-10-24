//! Copying a file's bytes without moving them through this process, where the
//! platform has a call for it.
//!
//! A backup of a sealed segment is a copy of bytes that will never change
//! again, which is the one thing filesystems are good at doing by themselves:
//! APFS clones a file by sharing its extents, and Linux hands the copy to the
//! filesystem, which does the same on XFS and btrfs and reads and writes it in
//! the kernel otherwise.
//!
//! Every call here may be refused, `error.Unsupported`, for the reasons that
//! mean the platform or this pair of files cannot share extents: a filesystem
//! that will not, a kernel without the call, two files on different mounts.
//! The answer is then a byte copy, which is what this package did before and
//! what it still does there. Any other failure -- a full disk, an I/O error, a
//! refused permission, a cancel -- is returned: the byte copy would meet it
//! too, or hide it.
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
pub const available = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .linux => true,
    else => false,
};

pub const Error = error{
    /// The platform cannot share these extents; copy the bytes.
    Unsupported,
    /// `name` is not in the source.
    FileNotFound,
    /// The destination already holds `name`.
    PathAlreadyExists,
    /// The source holds fewer bytes than asked for.
    ShortSource,
    AccessDenied,
    NoSpaceLeft,
    DiskQuota,
    FileTooBig,
    InputOutput,
    Unexpected,
} || Io.File.OpenError || Io.File.StatError;

/// Copy the whole of `name` from `source` into `dest`. `Unsupported` means
/// nothing was written and the caller copies the bytes itself.
///
/// `dest` must not already hold `name`: Darwin's clone refuses a destination
/// that exists (`PathAlreadyExists`), and the caller removes it first.
pub fn whole(io: Io, source: Io.Dir, dest: Io.Dir, name: [:0]const u8) Error!void {
    if (!available) return error.Unsupported;
    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => while (true) {
            if (clonefileat(source.handle, name, dest.handle, name, 0) == 0) return;
            return switch (std.posix.errno(@as(c_int, -1))) {
                .INTR => continue,
                // A volume that does not clone, or two volumes.
                .OPNOTSUPP, .XDEV => error.Unsupported,
                .NOENT => error.FileNotFound,
                .EXIST => error.PathAlreadyExists,
                .ACCES, .PERM => error.AccessDenied,
                .NOSPC => error.NoSpaceLeft,
                .DQUOT => error.DiskQuota,
                .IO => error.InputOutput,
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
        .linux => {
            const from = try source.openFile(io, name, .{});
            defer from.close(io);
            const length = try from.length(io);
            const to = try dest.createFile(io, name, .{ .truncate = true });
            defer to.close(io);
            return range(to, from, length);
        },
        else => return error.Unsupported,
    }
}

/// Copy the first `length` bytes of one open file into another, from offset
/// zero. `Unsupported` means the platform copied none of them, and the caller
/// copies them all itself.
pub fn range(to: Io.File, from: Io.File, length: u64) Error!void {
    if (builtin.target.os.tag != .linux) return error.Unsupported;
    var at: u64 = 0;
    while (at < length) {
        var in: i64 = @intCast(at);
        var out: i64 = @intCast(at);
        const want: usize = @intCast(length - at);
        const moved = std.os.linux.copy_file_range(from.handle, &in, to.handle, &out, want, 0);
        switch (std.posix.errno(moved)) {
            .SUCCESS => {},
            .INTR => continue,
            // A filesystem that will not do it, a kernel that does not have
            // it, two files on different mounts: the caller copies the bytes,
            // from the start, over whatever went before.
            .XDEV, .OPNOTSUPP, .NOSYS, .INVAL => return error.Unsupported,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .PERM, .ACCES => return error.AccessDenied,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        // The file was longer a moment ago.
        if (moved == 0) return error.ShortSource;
        at += moved;
    }
}
