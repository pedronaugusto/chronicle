//! Making bytes durable, which is not one call on the three platforms this
//! package runs on.
//!
//! `Io.File.sync` is `fsync(2)` everywhere it is POSIX. On Darwin `fsync`
//! returns once the bytes are in the drive's write cache and not once they are
//! on its media, so a log that promises to survive a power cut has to ask for
//! `F_FULLFSYNC` instead. On Linux the cheaper call is the useful one in the
//! other direction: `fdatasync` skips the metadata a read-back does not need,
//! which is worth having exactly when the file's length is not changing —
//! which is what preallocation is for.
//!
//! This file is internal. `chronicle.zig` is the package.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// The call this platform makes for a durable write.
pub const Flush = enum {
    /// `fcntl(F_FULLFSYNC)`: the bytes are on the drive's media, not only in
    /// its write cache. Darwin, where `fsync` promises the weaker thing.
    full_fsync,
    /// `fsync(2)`, or `fdatasync(2)` for a write that did not change the
    /// file's length. What that means past the drive's cache is the drive's
    /// promise and the operating system's.
    fsync,
    /// `NtFlushBuffersFile`, which is what `Io.File.sync` does on Windows.
    flush_buffers,
};

/// What `Sync.always` issues here. `chronicle.flush` re-exports it, and
/// README.md's durability table is written per platform from it.
pub const flush: Flush = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => .full_fsync,
    .windows => .flush_buffers,
    else => .fsync,
};

/// How much of a file has to reach the disk.
pub const Level = enum {
    /// The contents and whatever metadata a reader needs to find them. What
    /// an append that extended the file asks for.
    whole,
    /// The contents only. Sufficient — and only sufficient — when the write
    /// went into space the file already had, which is what preallocation
    /// arranges.
    contents,
};

/// Make `file`'s bytes durable, as far as this platform can be asked.
///
/// The Darwin and Linux paths issue their syscall on the file's handle
/// directly, because `Io` has one flush and it is the wrong one on both. The
/// call blocks the calling thread, as `Io.File.sync` does, and is not
/// cancellable; a failure comes back as the same error set either way.
pub fn sync(io: Io, file: Io.File, level: Level) Io.File.SyncError!void {
    switch (flush) {
        .full_fsync => {
            // ENOTSUP is a filesystem that has no media flush to ask for --
            // a network mount, a container layer. The weaker call is then
            // everything there is, and README.md says what that is worth.
            switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
                .SUCCESS => return,
                .INVAL, .OPNOTSUPP => return file.sync(io),
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                else => return file.sync(io),
            }
        },
        .fsync => {
            if (level == .contents and builtin.os.tag == .linux) {
                std.posix.fdatasync(file.handle) catch |err| switch (err) {
                    error.InputOutput => return error.InputOutput,
                    error.NoSpaceLeft => return error.NoSpaceLeft,
                    error.DiskQuota => return error.DiskQuota,
                    else => return file.sync(io),
                };
                return;
            }
            return file.sync(io);
        },
        .flush_buffers => return file.sync(io),
    }
}
