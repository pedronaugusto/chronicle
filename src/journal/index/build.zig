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

/// The shortest a record's line can be, its seq, time, version, payload and
/// checksum: what sizes the index memory a full segment can need.
pub const smallest_record_bytes = 32;

/// The active segment would pass its index memory: it is sealed early.
pub const BudgetError = error{IndexMemory};

/// A key too long for an index: refused before its record is written.
pub const KeyError = error{KeyTooLong};

/// One record of a pending exact index, 16 bytes: its key's number in the key
/// table, its seq as a count past the segment's first, and its offset.
const ExactPosted = extern struct { key: u32, seq: u32, offset: u64 };

/// One record of a pending ordered index, 24 bytes: its key, its offset, and
/// its seq as a count past the segment's first.
const OrderedPosted = extern struct { key: u64, offset: u64, seq: u32, pad: u32 = 0 };

/// Where a distinct key's bytes lie in the table's heap.
const KeySpan = struct { at: u32, len: u32 };

/// What a record is charged: 16 bytes in an exact index, 24 in an ordered one.
pub fn entryBytes(kind: format.Kind) Bytes {
    return .fromRaw(switch (kind) {
        .exact => @sizeOf(ExactPosted),
        .ordered => @sizeOf(OrderedPosted),
    });
}

comptime {
    if (@sizeOf(ExactPosted) != 16 or @sizeOf(OrderedPosted) != 24) @compileError("chronicle: a pending record's size is the index memory's budget per record");
}

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
        /// The segment's first record, which the records' seqs count from.
        base: Seq = .fromRaw(0),
        exact: std.ArrayList(ExactPosted) = .empty,
        ordered: std.ArrayList(OrderedPosted) = .empty,
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
        pub fn addExact(p: *Self, gpa: Allocator, budget: *Budget, key: []const u8, seq: Seq, offset: Bytes) (Allocator.Error || BudgetError || KeyError)!void {
            if (key.len > format.max_key_bytes) return error.KeyTooLong;
            const counted = try p.past(seq);
            const found = p.table.getKeyAdapted(key, ByBytes{ .pending = p });
            const key_cost: Bytes = if (found == null) values.plus(Bytes.fromRaw(key.len), key_overhead) else values.no_bytes;
            const cost = values.plus(key_cost, entryBytes(.exact));
            if (!budget.fits(cost)) return error.IndexMemory;
            try p.exact.ensureUnusedCapacity(gpa, 1);
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
            p.exact.appendAssumeCapacity(.{ .key = number, .seq = counted, .offset = offset.raw() });
            p.charge(budget, cost);
        }

        /// `seq` as a count past the segment's first: a segment of more than
        /// four billion records has no room in this index, and seals early.
        fn past(p: *const Self, seq: Seq) BudgetError!u32 {
            const gap = p.base.distanceTo(seq) catch return error.IndexMemory;
            return std.math.cast(u32, gap.raw()) orelse error.IndexMemory;
        }

        /// What a record whose exact key is `key` would be charged: its
        /// entry, and the key's bytes when the key is new.
        pub fn costOf(p: *const Self, key: []const u8) Bytes {
            if (p.table.containsAdapted(key, ByBytes{ .pending = p })) return entryBytes(.exact);
            return values.plus(values.plus(entryBytes(.exact), key_overhead), Bytes.fromRaw(key.len));
        }

        /// A record whose ordered key is `key` added, charged to `budget`.
        pub fn addOrdered(p: *Self, gpa: Allocator, budget: *Budget, key: u64, seq: Seq, offset: Bytes) (Allocator.Error || BudgetError)!void {
            const counted = try p.past(seq);
            if (!budget.fits(entryBytes(.ordered))) return error.IndexMemory;
            try p.ordered.append(gpa, .{ .key = key, .seq = counted, .offset = offset.raw() });
            p.charge(budget, entryBytes(.ordered));
        }

        /// How many records it holds.
        pub fn len(p: *const Self) usize {
            return p.exact.items.len + p.ordered.items.len;
        }

        /// The records past the first `kept` taken back, their entries'
        /// memory given back to `budget`: a batch staged and taken back. Keys
        /// they interned stay, charged, for the segment's later records.
        pub fn rollback(p: *Self, budget: *Budget, kept: usize) void {
            inline for (.{ &p.exact, &p.ordered }, .{ format.Kind.exact, format.Kind.ordered }) |list, kind| {
                if (kept < list.items.len) {
                    const back = entryBytes(kind).mul(list.items.len - kept) catch aegis.assert.never("the records taken back were each charged, so their total fits");
                    budget.used = values.minus(budget.used, back);
                    p.charged = values.minus(p.charged, back);
                    list.shrinkRetainingCapacity(kept);
                }
            }
        }

        /// Every key and record dropped and given back to `budget`, to start
        /// the segment whose first record is `base`; the memory is kept.
        pub fn clear(p: *Self, budget: *Budget, base: Seq) void {
            budget.used = values.minus(budget.used, p.charged);
            p.charged = values.no_bytes;
            p.base = base;
            p.heap.clearRetainingCapacity();
            p.spans.clearRetainingCapacity();
            p.table.clearRetainingCapacity();
            p.exact.clearRetainingCapacity();
            p.ordered.clearRetainingCapacity();
        }

        pub fn deinit(p: *Self, gpa: Allocator) void {
            p.heap.deinit(gpa);
            p.spans.deinit(gpa);
            p.table.deinit(gpa);
            p.exact.deinit(gpa);
            p.ordered.deinit(gpa);
            p.* = undefined;
        }

        /// The index file of these entries for segment and index `of`, into
        /// `out`: each record under its own whole key.
        pub fn encode(p: *const Self, gpa: Allocator, of: format.Of, out: *std.ArrayList(u8)) Allocator.Error!void {
            aegis.assert.invariant(!of.extra and of.base_seq.eql(p.base), "a pending index keeps no extra column, and is encoded for its own segment");
            const entries = try gpa.alloc(format.Entry, p.len());
            defer gpa.free(entries);
            switch (of.kind) {
                .exact => for (entries, p.exact.items) |*e, posted| {
                    e.* = .exact(p.keyBytes(posted.key), p.base.advance(.fromRaw(posted.seq)) catch aegis.assert.never("a record noted past the segment's first is a seq it was"), .fromRaw(posted.offset), 0);
                },
                .ordered => for (entries, p.ordered.items) |*e, posted| {
                    e.* = .ordered(posted.key, p.base.advance(.fromRaw(posted.seq)) catch aegis.assert.never("a record noted past the segment's first is a seq it was"), .fromRaw(posted.offset));
                },
            }
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
    const first = values.plus(values.plus(entryBytes(.exact), key_overhead), Bytes.fromRaw(1));
    // Room for a record with a new key and a second record of the same key.
    var budget: Budget = .{ .limit = values.plus(first, entryBytes(.exact)) };
    var p: Pending = .{};
    defer p.deinit(gpa);
    p.clear(&budget, .fromRaw(1));
    try p.addExact(gpa, &budget, "a", .fromRaw(1), .fromRaw(0));
    try p.addExact(gpa, &budget, "a", .fromRaw(2), .fromRaw(10));
    try testing.expectError(error.IndexMemory, p.addExact(gpa, &budget, "b", .fromRaw(3), .fromRaw(20)));
    try testing.expectEqual(2, p.len());
    try testing.expectEqual(1, p.spans.items.len);
    // A batch taken back gives back its records' memory.
    p.rollback(&budget, 1);
    try testing.expectEqual(1, p.len());
    try p.addExact(gpa, &budget, "a", .fromRaw(2), .fromRaw(10));
    p.clear(&budget, .fromRaw(3));
    try testing.expect(budget.used.eql(values.no_bytes));
    try p.addExact(gpa, &budget, "b", .fromRaw(3), .fromRaw(20));
    var long: [format.max_key_bytes + 1]u8 = @splat('k');
    try testing.expectError(error.KeyTooLong, p.addExact(gpa, &budget, &long, .fromRaw(4), .fromRaw(30)));
    // A record before the segment's first has no place in its index.
    try testing.expectError(error.IndexMemory, p.addExact(gpa, &budget, "b", .fromRaw(2), .fromRaw(30)));
}

fn sameHash(_: []const u8) u64 {
    return 7;
}

test "keys sharing a hash are kept apart, and each record is filed under its own key at the seal" {
    const gpa = testing.allocator;
    var budget: Budget = .{ .limit = values.furthest };
    var p: PendingWith(sameHash) = .{};
    defer p.deinit(gpa);
    p.clear(&budget, .fromRaw(10));
    const keys = [_][]const u8{ "alpha", "beta", "alpha", "a key longer than eight bytes", "beta", "gamma" };
    for (keys, 0..) |k, i| try p.addExact(gpa, &budget, k, .fromRaw(10 + i), .fromRaw(i * 8));
    try testing.expectEqual(4, p.spans.items.len);
    const of: format.Of = .{ .base_seq = .fromRaw(10), .segment_bytes = .fromRaw(100), .name = "kind", .version = 1, .kind = .exact };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.encode(gpa, of, &out);
    const index = try format.Index.parse(.init(out.items), of);
    try testing.expectEqual(4, index.keys);
    for (keys) |k| {
        const run = index.find(k);
        // Each record found under its key is one that was added with it.
        for (run.first..run.end) |i| try testing.expectEqualStrings(k, keys[index.at(i).seq.raw() - 10]);
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
    p.clear(&budget, .fromRaw(5));
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
