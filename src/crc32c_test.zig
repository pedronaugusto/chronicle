//! Stored CRC-32C values captured from chronicle c5d421c before its removal.
//! Each little-endian row is length, offset, hash, and continued CRC from
//! 0x12345678. The input formula below covers every length through 33 and
//! +/-9 bytes at 64, 192, 256, 768, 1024, 4096, 24576, 49152, 65536, 98304.
const std = @import("std");
const chronicle = @import("chronicle.zig");
const warp = @import("warp");
const shakedown = @import("shakedown");

test "CRC-32C preserves the old implementation's captured outputs" {
    const vectors = @embedFile("testing/crc32c.bin");
    var buf: [98368 + 8]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate((i *% 0x9e3779b1) >> 11);
    var at: usize = 0;
    while (at < vectors.len) : (at += 16) {
        const row = vectors[at..][0..16];
        const len = std.mem.readInt(u32, row[0..4], .little);
        const offset = std.mem.readInt(u32, row[4..8], .little);
        const expected = std.mem.readInt(u32, row[8..12], .little);
        const continued = std.mem.readInt(u32, row[12..16], .little);
        const bytes = buf[offset..][0..len];
        try std.testing.expectEqual(expected, chronicle.checksum(bytes));
        try std.testing.expectEqual(continued, warp.crc32c(0x12345678, bytes));
        const cut = len / 2;
        var running: warp.Crc32c = .init;
        running.update(bytes[0..cut]);
        running.update(bytes[cut..]);
        try std.testing.expectEqual(expected, running.final());
    }
}

// Index entries are 24 bytes; the index reader carries them in 64 KiB chunks.
fn checksumChunks(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try shakedown.gen.slice(case.source, u8, byte, case.gpa, .{ .max_len = 65536, .average = 4096 });
    const cut = shakedown.gen.intRange(case.source, usize, 0, bytes.len);
    var running: warp.Crc32c = .init;
    running.update(bytes[0..cut]);
    running.update(&.{});
    running.update(bytes[cut..]);
    const expected = std.hash.crc.@"CRC-32/ISCSI".hash(bytes);
    try std.testing.expectEqual(expected, chronicle.checksum(bytes));
    try std.testing.expectEqual(expected, running.final());
}

fn byte(source: *shakedown.Source) u8 {
    return shakedown.gen.int(source, u8);
}

test "CRC-32C streaming preserves index chunks over arbitrary bytes and cuts" {
    try shakedown.check(std.testing.allocator, {}, checksumChunks, .{ .cases = 128 });
}
