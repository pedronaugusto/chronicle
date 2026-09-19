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
    if (!hardware) return table(from, bytes);

    var crc: u32 = from;
    var at: usize = 0;
    while (at + 8 <= bytes.len) : (at += 8) {
        crc = eight(crc, std.mem.readInt(u64, bytes[at..][0..8], .little));
    }
    // The last seven bytes go through the table. Both instruction sets have
    // forms for a byte, two and four, and none of them is worth carrying a
    // second code path for: a record is a hundred bytes, of which this is at
    // most seven.
    return table(crc, bytes[at..]);
}

fn table(from: u32, bytes: []const u8) u32 {
    var state: std.hash.crc.Crc32Iscsi = .{ .crc = from };
    state.update(bytes);
    return state.crc;
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
