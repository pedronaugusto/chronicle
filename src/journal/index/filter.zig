//! The summary of an exact index: a split-block Bloom filter over its keys,
//! the layout Parquet's bloom filters use. The filter is blocks of 256 bits,
//! eight 32-bit words; a key's 64-bit hash picks one block with its high
//! half and sets one bit in each of the block's words with its low half and
//! eight salts. So a lookup reads one block, one cache line, and a key that
//! was added is always found; one that was not is found about one time in
//! two hundred at the sizing below.
//!
//! The filter lives in an index file as little-endian words, and is read
//! and set there, in place.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");

/// The bytes of one block: eight 32-bit words.
pub const block_bytes = 32;

/// The bits a key is given: at this sizing about one false positive in two
/// hundred, measured by the tests, under the one in a hundred an index's
/// filter is held to.
pub const bits_per_key = 12;

/// Parquet's salts, one per word of a block.
const salts = [8]u32{ 0x47b6137b, 0x44974d91, 0x8824ad5b, 0xa2b7289d, 0x705495c7, 0x2df1424b, 0x9efc4947, 0x5c6bfb31 };

/// The seed of the keys' hash, so that the filter's hash is its own: it is
/// a hash for a filter, not a checksum, which is warp's.
const seed = 0x63726f6e69636c65;

/// A key's hash, which the filter and an index's long keys both use.
pub fn hash(key: []const u8) u64 {
    return std.hash.XxHash3.hash(seed, key);
}

/// How many blocks a filter over `keys` distinct keys takes: at least one.
pub fn blocksFor(keys: usize) usize {
    const bits = keys *| bits_per_key;
    return @max(1, bits / (block_bytes * 8) + @intFromBool(bits % (block_bytes * 8) != 0));
}

/// The block `h` falls in, among `blocks`: the high half of the hash scaled
/// to the count, which spreads the hashes over any count without a division.
fn blockOf(h: u64, blocks: usize) usize {
    return @intCast(((h >> 32) * @as(u64, blocks)) >> 32);
}

/// The bit of each word of a block that `h` sets.
fn masks(h: u64) [8]u32 {
    // The low half of the hash; @truncate takes those bits, which are the point.
    const low: u32 = @truncate(h);
    var out: [8]u32 = undefined;
    for (&out, salts) |*m, salt| m.* = @as(u32, 1) << @intCast((low *% salt) >> 27);
    return out;
}

/// Sets `h`'s bits in `filter`, a whole number of blocks.
pub fn add(filter: []u8, h: u64) void {
    const block = filter[blockOf(h, filter.len / block_bytes) * block_bytes ..][0..block_bytes];
    for (masks(h), 0..) |m, i| {
        const word = block[i * 4 ..][0..4];
        std.mem.writeInt(u32, word, std.mem.readInt(u32, word, .little) | m, .little);
    }
}

/// Whether a key whose hash is `h` may have been added to `filter`, a whole
/// number of blocks: false is certain.
pub fn mayHold(filter: []const u8, h: u64) bool {
    if (filter.len < block_bytes) return false;
    const block = filter[blockOf(h, filter.len / block_bytes) * block_bytes ..][0..block_bytes];
    for (masks(h), 0..) |m, i| {
        if (std.mem.readInt(u32, block[i * 4 ..][0..4], .little) & m == 0) return false;
    }
    return true;
}

const testing = std.testing;

test "every key added is found, and a key not added is found under one time in a hundred" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x66696c74);
    const random = prng.random();
    for ([_]usize{ 1, 10, 1000, 100_000 }) |keys| {
        const filter = try gpa.alloc(u8, blocksFor(keys) * block_bytes);
        defer gpa.free(filter);
        @memset(filter, 0);
        // Keys are the integers below `keys` as eight bytes; strangers lie above them.
        for (0..keys) |k| add(filter, hash(std.mem.asBytes(&@as(u64, k))));
        for (0..keys) |k| try testing.expect(mayHold(filter, hash(std.mem.asBytes(&@as(u64, k)))));
        if (keys < 1000) continue;
        var found: usize = 0;
        const trials = 100_000;
        for (0..trials) |_| {
            const stranger = random.intRangeAtMost(u64, keys, std.math.maxInt(u64));
            if (mayHold(filter, hash(std.mem.asBytes(&stranger)))) found += 1;
        }
        try testing.expect(found * 100 < trials);
    }
}

test "an empty filter holds nothing, and the blocks a count takes" {
    try testing.expect(!mayHold(&.{}, hash("a")));
    var one: [block_bytes]u8 = @splat(0);
    try testing.expect(!mayHold(&one, hash("a")));
    try testing.expectEqual(1, blocksFor(0));
    try testing.expectEqual(1, blocksFor(21));
    try testing.expectEqual(2, blocksFor(22));
}
