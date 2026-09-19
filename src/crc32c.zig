//! CRC32C, through the instruction for it where the machine has one.
//!
//! The value is the one `std.hash.crc.Crc32Iscsi` produces — same polynomial,
//! same reflection, same initial and final words — and the suite asserts that
//! over every length up to a segment's read buffer. What differs is how it is
//! computed: the table version steps one byte at a time, and both aarch64 and
//! x86-64 have had an instruction that does eight since 2011.
//!
//! Which path is compiled is decided by the target's features, so a build for
//! a machine without the instruction gets the table and nothing else changes.
//!
//! This file is internal. `chronicle.zig` is the package.

const builtin = @import("builtin");
const std = @import("std");

/// Whether this target has the instruction.
pub const hardware = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
    else => false,
};

/// The CRC32C of `bytes`.
pub fn hash(bytes: []const u8) u32 {
    return ~update(initial, bytes);
}

/// What a running checksum starts from, for a value built out of several
/// pieces. `~` the last `update` is the checksum of the pieces joined.
pub const initial: u32 = 0xffff_ffff;

/// Carry a running checksum over `bytes`.
pub fn update(from: u32, bytes: []const u8) u32 {
    if (!hardware) {
        var table: std.hash.crc.Crc32Iscsi = .{ .crc = from };
        table.update(bytes);
        return table.crc;
    }

    var crc: u32 = from;
    var at: usize = 0;
    while (at + 8 <= bytes.len) : (at += 8) {
        crc = eight(crc, std.mem.readInt(u64, bytes[at..][0..8], .little));
    }
    if (at + 4 <= bytes.len) {
        crc = four(crc, std.mem.readInt(u32, bytes[at..][0..4], .little));
        at += 4;
    }
    if (at + 2 <= bytes.len) {
        crc = two(crc, std.mem.readInt(u16, bytes[at..][0..2], .little));
        at += 2;
    }
    if (at < bytes.len) crc = one(crc, bytes[at]);
    return crc;
}

inline fn eight(crc: u32, value: u64) u32 {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => return asm ("crc32cx %[out:w], %[in:w], %[value]"
            : [out] "=r" (-> u32),
            : [in] "r" (crc),
              [value] "r" (value),
        ),
        .x86_64 => {
            const wide: u64 = asm ("crc32q %[value], %[out]"
                : [out] "=r" (-> u64),
                : [in] "0" (@as(u64, crc)),
                  [value] "r" (value),
            );
            return @truncate(wide);
        },
        else => unreachable,
    }
}

inline fn four(crc: u32, value: u32) u32 {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => return asm ("crc32cw %[out:w], %[in:w], %[value:w]"
            : [out] "=r" (-> u32),
            : [in] "r" (crc),
              [value] "r" (value),
        ),
        .x86_64 => return asm ("crc32l %[value], %[out]"
            : [out] "=r" (-> u32),
            : [in] "0" (crc),
              [value] "r" (value),
        ),
        else => unreachable,
    }
}

inline fn two(crc: u32, value: u16) u32 {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => return asm ("crc32ch %[out:w], %[in:w], %[value:w]"
            : [out] "=r" (-> u32),
            : [in] "r" (crc),
              [value] "r" (value),
        ),
        .x86_64 => return asm ("crc32w %[value], %[out]"
            : [out] "=r" (-> u32),
            : [in] "0" (crc),
              [value] "r" (value),
        ),
        else => unreachable,
    }
}

inline fn one(crc: u32, value: u8) u32 {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => return asm ("crc32cb %[out:w], %[in:w], %[value:w]"
            : [out] "=r" (-> u32),
            : [in] "r" (crc),
              [value] "r" (value),
        ),
        .x86_64 => return asm ("crc32b %[value], %[out]"
            : [out] "=r" (-> u32),
            : [in] "0" (crc),
              [value] "r" (value),
        ),
        else => unreachable,
    }
}
