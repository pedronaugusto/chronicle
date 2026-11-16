//! Building a field index: the records with a key, gathered as the active
//! segment is appended to or as a sealed one is read, then written as the
//! segment's index file (`format.zig`) when it seals or is read.
//!
//! The active segment's index lives in memory: each distinct key once, whole,
//! in a key table found by the key's hash and compared byte for byte, and per
//! record its key's number, seq, offset and extra column. Two keys that share
//! a hash are two entries of the table, so every record is filed under its
//! own key and the seal reads nothing back. The memory is the records'
//! entries and the distinct keys' bytes, charged to a budget the journal
//! sets (`Options.index_memory`); past it the active segment seals early.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const values = @import("../values.zig");
const format = @import("format.zig");
const filter = @import("filter.zig");

const Seq = values.Seq;
const Bytes = values.Bytes;

/// What the entries of every index of the active segment may take.
pub const Budget = struct {
    limit: Bytes,
    used: Bytes = values.no_bytes,

    /// Whether `bytes` more fit.
    pub fn fits(b: Budget, bytes: Bytes) bool {
        const after = b.used.add(bytes) catch return false;
        return after.compare(b.limit) != .gt;
    }
};

/// The active segment would pass its index memory: it is sealed early.
pub const BudgetError = error{IndexMemory};

/// A key too long for an index: refused before its record is written.
pub const KeyError = error{KeyTooLong};

/// One record of a pending index: its key's number in the key table (an
/// exact index) or its key (an ordered one), its seq, offset and extra.
const Posted = struct { key: u64, seq: Seq, offset: Bytes, extra: u64 };

/// Where a distinct key's bytes lie in the table's heap.
const KeySpan = struct { at: u32, len: u32 };

/// What a record is charged.
pub const entry_bytes: Bytes = .fromRaw(@sizeOf(Posted));

/// What a distinct key is charged besides its bytes: its span and its slot in
/// the table.
pub const key_overhead: Bytes = .fromRaw(@sizeOf(KeySpan) + 2 * @sizeOf(u32));

/// One index's entries for one segment, keys interned by `keyHash`, which is the
/// filter's but for the tests that make keys share one.
pub fn PendingWith(comptime keyHash: fn ([]const u8) u64) type {
    return struct {
        const Self = @This();

        /// The distinct keys' bytes, each after the one before.
        heap: std.ArrayList(u8) = .empty,
        spans: std.ArrayList(KeySpan) = .empty,
        /// The key numbers, found by their bytes.
        table: std.HashMapUnmanaged(u32, void, TableContext, std.hash_map.default_max_load_percentage) = .empty,
        entries: std.ArrayList(Posted) = .empty,
        /// What the keys and entries were charged.
        charged: Bytes = values.no_bytes,

        const TableContext = struct {
            pending: *const Self,
            pub fn hash(c: TableContext, k: u32) u64 {
                return hashFn(c.pending.keyBytes(k));
            }
            pub fn eql(_: TableContext, a: u32, b: u32) bool {
                return a == b;
            }
        };

        const ByBytes = struct {
            pending: *const Self,
            pub fn hash(_: ByBytes, bytes: []const u8) u64 {
                return hashFn(bytes);
            }
            pub fn eql(c: ByBytes, bytes: []const u8, k: u32) bool {
                return std.mem.eql(u8, bytes, c.pending.keyBytes(k));
            }
        };

        const hashFn = keyHash;

        fn keyBytes(p: *const Self, k: u32) []const u8 {
            const span = p.spans.items[k];
            return p.heap.items[span.at..][0..span.len];
        }

        fn charge(p: *Self, budget: *Budget, bytes: Bytes) void {
            budget.used = values.plus(budget.used, bytes);
            p.charged = values.plus(p.charged, bytes);
        }

        /// A record whose exact key is `key` added, charged to `budget`, its
        /// key interned: `error.KeyTooLong` past `format.max_key_bytes`,
        /// `error.IndexMemory` when the budget would be passed. Nothing is
        /// added on an error.
        pub fn addExact(p: *Self, gpa: Allocator, budget: *Budget, key: []const u8, seq: Seq, offset: Bytes, extra: u64) (Allocator.Error || BudgetError || KeyError)!void {
            if (key.len > format.max_key_bytes) return error.KeyTooLong;
            const found = p.table.getKeyAdapted(key, ByBytes{ .pending = p });
            const key_cost: Bytes = if (found == null) values.plus(Bytes.fromRaw(key.len), key_overhead) else values.no_bytes;
            if (!budget.fits(values.plus(key_cost, entry_bytes))) return error.IndexMemory;
            try p.entries.ensureUnusedCapacity(gpa, 1);
            const number: u32 = found orelse number: {
                try p.heap.ensureUnusedCapacity(gpa, key.len);
                try p.spans.ensureUnusedCapacity(gpa, 1);
                const n: u32 = @intCast(p.spans.items.len);
                p.spans.appendAssumeCapacity(.{ .at = @intCast(p.heap.items.len), .len = @intCast(key.len) });
                p.heap.appendSliceAssumeCapacity(key);
                p.table.putContext(gpa, n, {}, .{ .pending = p }) catch |err| {
                    p.spans.items.len -= 1;
                    p.heap.items.len -= key.len;
                    return err;
                };
                break :number n;
            };
            p.entries.appendAssumeCapacity(.{ .key = number, .seq = seq, .offset = offset, .extra = extra });
            p.charge(budget, values.plus(key_cost, entry_bytes));
        }

        /// A record whose ordered key is `key` added, charged to `budget`.
        pub fn addOrdered(p: *Self, gpa: Allocator, budget: *Budget, key: u64, seq: Seq, offset: Bytes) (Allocator.Error || BudgetError)!void {
            if (!budget.fits(entry_bytes)) return error.IndexMemory;
            try p.entries.append(gpa, .{ .key = key, .seq = seq, .offset = offset, .extra = 0 });
            p.charge(budget, entry_bytes);
        }

        /// Every key and entry dropped and given back to `budget`; the memory
        /// is kept for the next segment.
        pub fn clear(p: *Self, budget: *Budget) void {
            budget.used = values.minus(budget.used, p.charged);
            p.charged = values.no_bytes;
            p.heap.clearRetainingCapacity();
            p.spans.clearRetainingCapacity();
            p.table.clearRetainingCapacity();
            p.entries.clearRetainingCapacity();
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            p.heap.deinit(gpa);
            p.spans.deinit(gpa);
            p.table.deinit(gpa);
            p.entries.deinit(gpa);
            p.* = undefined;
        }

        /// The index file of these entries for segment and index `of`, into
        /// `out`: each record under its own whole key.
        pub fn encode(p: *const Self, gpa: Allocator, of: format.Of, out: *std.ArrayList(u8)) Allocator.Error!void {
            const entries = try gpa.alloc(format.Entry, p.entries.items.len);
            defer gpa.free(entries);
            for (entries, p.entries.items) |*e, posted| e.* = switch (of.kind) {
                .exact => .exact(p.keyBytes(@intCast(posted.key)), posted.seq, posted.offset, posted.extra),
                .ordered => .ordered(posted.key, posted.seq, posted.offset),
            };
            return format.encode(gpa, of, entries, out);
        }
    };
}

/// A pending index over the filter's hash.
pub const Pending = PendingWith(filter.hash);

/// The longest index file name: a segment's 20 digits, `.`, the index's
/// name, and the extension.
pub const max_file_name = 20 + 1 + format.max_name_bytes + format.extension.len;

/// An index file's name: `<base>.<name>.cdx`, the segment's first record in
/// 20 digits as the segment's own file is named.
pub const FileName = struct {
    buffer: [max_file_name]u8,
    len: usize,

    pub fn of(base_seq: Seq, name: []const u8) FileName {
        aegis.assert.invariant(format.validName(name), "an index's name is checked before it names a file");
        var out: FileName = .{ .buffer = undefined, .len = 0 };
        const written = std.mem.print(&out.buffer, "{d:0>20}.{s}" ++ format.extension, .{ base_seq.raw(), name }) catch aegis.assert.never("every u64 fits in 20 digits and a valid name in 32 bytes");
        out.len = written.len;
        return out;
    }

    pub fn slice(f: *const FileName) []const u8 {
        return f.buffer[0..f.len];
    }
};

const testing = std.testing;

test "records and new keys are charged to the budget, refused past it, and given back when cleared" {
    const gpa = testing.allocator;
    const first = values.plus(values.plus(entry_bytes, key_overhead), Bytes.fromRaw(1));
    // Room for a record with a new key and a second record of the same key.
    var budget: Budget = .{ .limit = values.plus(first, entry_bytes) };
    var p: Pending = .{};
    defer p.deinit(gpa);
    try p.addExact(gpa, &budget, "a", .fromRaw(1), .fromRaw(0), 0);
    try p.addExact(gpa, &budget, "a", .fromRaw(2), .fromRaw(10), 0);
    try testing.expectError(error.IndexMemory, p.addExact(gpa, &budget, "b", .fromRaw(3), .fromRaw(20), 0));
    try testing.expectEqual(2, p.entries.items.len);
    try testing.expectEqual(1, p.spans.items.len);
    p.clear(&budget);
    try testing.expect(budget.used.eql(values.no_bytes));
    try p.addExact(gpa, &budget, "b", .fromRaw(3), .fromRaw(20), 0);
    var long: [format.max_key_bytes + 1]u8 = @splat('k');
    try testing.expectError(error.KeyTooLong, p.addExact(gpa, &budget, &long, .fromRaw(4), .fromRaw(30), 0));
}

fn sameHash(_: []const u8) u64 {
    return 7;
}

test "keys sharing a hash are kept apart, and each record is filed under its own key at the seal" {
    const gpa = testing.allocator;
    var budget: Budget = .{ .limit = values.furthest };
    var p: PendingWith(sameHash) = .{};
    defer p.deinit(gpa);
    const keys = [_][]const u8{ "alpha", "beta", "alpha", "a key longer than eight bytes", "beta", "gamma" };
    for (keys, 0..) |k, i| try p.addExact(gpa, &budget, k, .fromRaw(10 + i), .fromRaw(i * 8), i);
    try testing.expectEqual(4, p.spans.items.len);
    const of: format.Of = .{ .base_seq = .fromRaw(10), .segment_bytes = .fromRaw(100), .name = "kind", .version = 1, .kind = .exact, .extra = true };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.encode(gpa, of, &out);
    const index = try format.Index.parse(.init(out.items), of);
    try testing.expectEqual(4, index.keys);
    for (keys) |k| {
        const run = index.find(k);
        // Each record found under its key is one that was added with it.
        for (run.first..run.end) |i| try testing.expectEqualStrings(k, keys[index.at(i).extra]);
        var expected: usize = 0;
        for (keys) |other| expected += @intFromBool(std.mem.eql(u8, other, k));
        try testing.expectEqual(expected, run.end - run.first);
    }
}

test "an ordered pending index encodes its keys, and its file is named for the segment and the index" {
    const gpa = testing.allocator;
    var budget: Budget = .{ .limit = values.furthest };
    var p: Pending = .{};
    defer p.deinit(gpa);
    try p.addOrdered(gpa, &budget, format.orderedKey(@as(i64, -3)), .fromRaw(5), .fromRaw(0));
    try p.addOrdered(gpa, &budget, format.orderedKey(@as(i64, 4)), .fromRaw(6), .fromRaw(9));
    const of: format.Of = .{ .base_seq = .fromRaw(5), .segment_bytes = .fromRaw(100), .name = "amount", .version = 1, .kind = .ordered };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.encode(gpa, of, &out);
    const index = try format.Index.parse(.init(out.items), of);
    const run = index.range(format.orderedKey(@as(i64, 0)), format.orderedKey(@as(i64, 10)));
    try testing.expectEqual(1, run.end - run.first);
    const name: FileName = .of(.fromRaw(5), "kind");
    try testing.expectEqualStrings("00000000000000000005.kind.cdx", name.slice());
}
