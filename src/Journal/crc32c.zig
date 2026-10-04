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
    // A record is shorter than three blocks and goes straight to the one
    // chain below; the three are for the buffers that are not.
    if (bytes.len >= 3 * short) at = interleaved(&crc, bytes);
    while (at + 8 <= bytes.len) : (at += 8) {
        crc = eight(crc, std.mem.readInt(u64, bytes[at..][0..8], .little));
    }
    // The last seven bytes go through the table. Both instruction sets have
    // forms for a byte, two and four, and none of them is worth carrying a
    // second code path for: a record is a hundred bytes, of which this is at
    // most seven.
    return table(crc, bytes[at..]);
}

/// The block lengths of the three chains, in bytes: long buffers in blocks
/// of `long`, what is left of them in blocks of `short`. These are the
/// lengths the crc32c crates use. Each must be a power of two and a multiple
/// of eight.
const long = 8192;
const short = 256;

/// One instruction folds in eight bytes, but takes three cycles to give its
/// answer to the next, so one chain of them leaves two thirds of the unit
/// idle. Three chains over three blocks keep it busy, and a table shifts the
/// first chain's answer past the bytes of the next two, which is how zlib-ng
/// and the crc32c crates go through a long buffer. Carries `crc` over the
/// runs of three blocks at the front of `bytes` and returns how many bytes
/// that was.
noinline fn interleaved(crc: *u32, bytes: []const u8) usize {
    crc.* = threeWays(long, crc.*, bytes);
    var at = bytes.len - bytes.len % (3 * long);
    crc.* = threeWays(short, crc.*, bytes[at..]);
    at += (bytes.len - at) - (bytes.len - at) % (3 * short);
    return at;
}

/// `crc` carried over every whole run of three `block`-byte blocks at the
/// front of `bytes`.
inline fn threeWays(comptime block: usize, from: u32, bytes: []const u8) u32 {
    const shift = comptime Shift.over(block);
    var crc0 = from;
    var at: usize = 0;
    while (at + 3 * block <= bytes.len) : (at += 3 * block) {
        const run = bytes[at..][0 .. 3 * block];
        var crc1: u32 = 0;
        var crc2: u32 = 0;
        var i: usize = 0;
        while (i < block) : (i += 8) {
            crc0 = eight(crc0, std.mem.readInt(u64, run[i..][0..8], .little));
            crc1 = eight(crc1, std.mem.readInt(u64, run[block + i ..][0..8], .little));
            crc2 = eight(crc2, std.mem.readInt(u64, run[2 * block + i ..][0..8], .little));
        }
        // A CRC is linear: the chain that started at zero over the second
        // block, plus the first chain's answer carried past that block's
        // zeros, is the one chain over both.
        crc0 = shift.apply(crc0) ^ crc1;
        crc0 = shift.apply(crc0) ^ crc2;
    }
    return crc0;
}

/// What carrying a running CRC over `n` zero bytes does to it, as four
/// tables of what each byte of it becomes (Mark Adler's `crc32c_zeros`).
const Shift = struct {
    bytes: [4][256]u32,

    fn apply(self: *const Shift, crc: u32) u32 {
        return self.bytes[0][@as(u8, @truncate(crc))] ^
            self.bytes[1][@as(u8, @truncate(crc >> 8))] ^
            self.bytes[2][@as(u8, @truncate(crc >> 16))] ^
            self.bytes[3][@as(u8, @truncate(crc >> 24))];
    }

    /// Built at compile time; `n` is a power of two.
    fn over(comptime n: usize) Shift {
        @setEvalBranchQuota(200_000);
        const op = zeros(n);
        var shift: Shift = undefined;
        for (0..4) |i| {
            for (0..256) |b| shift.bytes[i][b] = times(op, @as(u32, @intCast(b)) << @intCast(8 * i));
        }
        return shift;
    }

    /// A matrix over GF(2) times a vector: the columns `vector` selects.
    fn times(matrix: [32]u32, vector: u32) u32 {
        var sum: u32 = 0;
        var v = vector;
        var i: usize = 0;
        while (v != 0) : ({
            v >>= 1;
            i += 1;
        }) {
            if (v & 1 != 0) sum ^= matrix[i];
        }
        return sum;
    }

    fn square(matrix: [32]u32) [32]u32 {
        var out: [32]u32 = undefined;
        for (&out, matrix) |*row, column| row.* = times(matrix, column);
        return out;
    }

    /// The operator for `n` zero bytes, by squaring the one for a zero bit.
    fn zeros(n: usize) [32]u32 {
        // One zero bit: shift right, and fold the polynomial in where a one
        // falls off.
        var op: [32]u32 = undefined;
        op[0] = polynomial;
        for (1..32) |i| op[i] = @as(u32, 1) << @intCast(i - 1);
        // Three squarings make the operator for one byte, and each one after
        // that doubles it.
        for (0..3) |_| op = square(op);
        var left = n;
        while (left > 1) : (left >>= 1) op = square(op);
        return op;
    }
};

/// CRC32C's polynomial, bit-reflected.
const polynomial: u32 = 0x82f6_3b78;

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

test "the checksum carries the iSCSI test vectors" {
    // RFC 3720, B.4, and the check value of the CRC catalogue.
    try std.testing.expectEqual(@as(u32, 0xe306_9283), hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0x8a91_36aa), hash(&(.{0x00} ** 32)));
    try std.testing.expectEqual(@as(u32, 0x62a8_ab43), hash(&(.{0xff} ** 32)));
    var up: [32]u8 = undefined;
    var down: [32]u8 = undefined;
    for (&up, &down, 0..) |*u, *d, i| {
        u.* = @intCast(i);
        d.* = @intCast(31 - i);
    }
    try std.testing.expectEqual(@as(u32, 0x46dd_794e), hash(&up));
    try std.testing.expectEqual(@as(u32, 0x113f_db5c), hash(&down));
}

test "the checksum agrees with the table over the lengths the chains change at" {
    const bytes = try std.testing.allocator.alloc(u8, 4 * 3 * long + 64);
    defer std.testing.allocator.free(bytes);
    var prng: std.Random.DefaultPrng = .init(0x63726333);
    prng.random().bytes(bytes);
    for ([_]usize{ 3 * short, 3 * long, 2 * 3 * long, 64 * 1024 }) |edge| {
        for (edge - 9..edge + 10) |length| {
            for (0..3) |start| {
                const slice = bytes[start..][0..length];
                try std.testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(slice), hash(slice));
            }
        }
    }
    // A checksum carried across pieces is the checksum of the pieces joined.
    const whole = bytes[0 .. 3 * long + 3 * short + 13];
    for ([_]usize{ 0, 1, 7, 8, 3 * short, 3 * long - 1, 3 * long + 5, whole.len }) |cut| {
        try std.testing.expectEqual(hash(whole), ~update(update(initial, whole[0..cut]), whole[cut..]));
    }
}

fn fuzzChecksum(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [3 * long + 3 * short + 64]u8 = undefined;
    const length = smith.slice(&buf);
    const bytes = buf[0..length];
    const cut = @min(smith.valueRangeAtMost(u16, 0, buf.len), length);
    try std.testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(bytes), hash(bytes));
    try std.testing.expectEqual(hash(bytes), ~update(update(initial, bytes[0..cut]), bytes[cut..]));
}

test "fuzz: the checksum is the table's over any bytes and any cut" {
    try std.testing.fuzz({}, fuzzChecksum, .{});
}
