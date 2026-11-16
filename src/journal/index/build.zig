//! Building a field index: the records with a key, gathered as the active
//! segment is appended to or as a sealed one is read, then written as the
//! segment's index file (`format.zig`) when it seals or is read.
//!
//! The active segment's index lives in memory: each distinct key once, whole,
//! in a key table found by the key's hash and compared byte for byte, and per
//! record its key's number, seq, offset and extra column. Two keys that share
//! a hash are two entries of the table, so every record is filed under its
//! own key and the seal reads nothing back. It allocates through a budget
//! (`Budget`, `Options.index_memory`) that charges every byte its lists and
//! table hold, before they hold it; past it the active segment seals early.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const values = @import("../values.zig");
const format = @import("format.zig");
const filter = @import("filter.zig");
const read = @import("read.zig");

const Seq = values.Seq;
const Bytes = values.Bytes;

/// What the indexes of the active segment may hold, and the allocator they
/// hold it through: over the journal's, charging every allocation, resize
/// and remap before it happens, refusing one that would pass the limit, and
/// crediting every free. So what is charged is what the lists and tables
/// really hold, their spare room and a growth's old and new storage
/// included. A refusal is `OutOfMemory` to the container that asked, and
/// `refused` says it was the limit.
pub const Budget = struct {
    child: Allocator,
    limit: Bytes,
    used: Bytes = values.no_bytes,
    /// The most it has held.
    most: Bytes = values.no_bytes,
    /// A request was refused for the limit since this was last cleared.
    refused: bool = false,

    pub fn init(child: Allocator, limit: Bytes) Budget {
        return .{ .child = child, .limit = limit };
    }

    /// The allocator that charges it. `b` must stay where it is while
    /// anything it allocated is held.
    pub fn allocator(b: *Budget) Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// `bytes` more taken, if they fit.
    fn take(b: *Budget, bytes: usize) bool {
        const after = b.used.add(.fromRaw(bytes)) catch return false;
        if (after.compare(b.limit) == .gt) {
            b.refused = true;
            return false;
        }
        b.used = after;
        if (b.most.compare(after) == .lt) b.most = after;
        return true;
    }

    fn give(b: *Budget, bytes: usize) void {
        b.used = values.minus(b.used, .fromRaw(bytes));
    }

    fn of(ctx: *anyopaque) *Budget {
        return @ptrCast(@alignCast(ctx)); // safe: allocator() hands out a Budget as the context
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const b = of(ctx);
        if (!b.take(len)) return null;
        return b.child.rawAlloc(len, alignment, ret_addr) orelse {
            b.give(len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const b = of(ctx);
        if (new_len > memory.len and !b.take(new_len - memory.len)) return false;
        if (!b.child.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) b.give(new_len - memory.len);
            return false;
        }
        if (new_len < memory.len) b.give(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const b = of(ctx);
        if (new_len > memory.len and !b.take(new_len - memory.len)) return null;
        const moved = b.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) b.give(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) b.give(memory.len - new_len);
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const b = of(ctx);
        b.child.rawFree(memory, alignment, ret_addr);
        b.give(memory.len);
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

/// What one index of a full segment really allocates, at most: as many
/// records as `max_segment_bytes` holds at the shortest a record can be, in
/// an exact index each with a distinct key of `longest_key` bytes. Per
/// record, std's lists hold up to half again what is in them (they grow by
/// half), and while one grows its old storage is held beside its new; the
/// key table is a power of two of slots (a byte of metadata and a `u32`)
/// at most 80% full, so up to 2.5 slots a key, and while it grows its old
/// slots beside its new. Hence, per record, an exact index: half again its
/// entry (16), its key's span (8) and its key, 2.5 slots (12.5), and the
/// largest old storage held in a growth; an ordered one: half again its
/// entry (24), and the entry again. And a page for the lists' and table's
/// first storage. A product past 64 bits is no limit.
pub fn fullSegment(max_segment_bytes: Bytes, kind: format.Kind, longest_key: usize) Bytes {
    const records = max_segment_bytes.ratio(.fromRaw(smallest_record_bytes)) catch aegis.assert.never("the shortest record is not zero bytes");
    // Twice the bytes a record takes, so the halves stay whole numbers.
    const twice: u64 = switch (kind) {
        .exact => 3 * (@sizeOf(ExactPosted) + @sizeOf(KeySpan) + @as(u64, longest_key)) + 5 * table_slot_bytes + 2 * @max(@sizeOf(ExactPosted), longest_key),
        .ordered => 3 * @sizeOf(OrderedPosted) + 2 * @sizeOf(OrderedPosted),
    };
    const all = Bytes.fromRaw(twice).mul(records) catch return values.furthest;
    const half = all.ratio(.fromRaw(2)) catch aegis.assert.never("two is not zero");
    return Bytes.fromRaw(half).add(first_storage) catch values.furthest;
}

/// A key table slot's bytes: its metadata byte and its key's number.
const table_slot_bytes = 1 + @sizeOf(u32);

/// A page for each index's lists' and table's first storage, past the
/// records' share of a full segment.
pub const first_storage: Bytes = .fromRaw(4096);

comptime {
    if (@sizeOf(ExactPosted) != 16 or @sizeOf(OrderedPosted) != 24 or @sizeOf(KeySpan) != 8) @compileError("chronicle: a pending record's sizes are what `fullSegment` counts");
}

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

        /// What a growth `budget` refused is: the limit, or memory.
        fn refusal(budget: *const Budget) (Allocator.Error || BudgetError) {
            return if (budget.refused) error.IndexMemory else error.OutOfMemory;
        }

        /// Room for `records` more records of an exact index, whose keys not
        /// yet interned take `new_key_bytes`, grown through `budget`:
        /// `error.IndexMemory` when it would pass its limit. What is grown
        /// stays, charged, until `deinit`.
        pub fn reserveExact(p: *Self, budget: *Budget, records: usize, new_key_bytes: usize) (Allocator.Error || BudgetError)!void {
            budget.refused = false;
            const gpa = budget.allocator();
            p.exact.ensureUnusedCapacity(gpa, records) catch return refusal(budget);
            if (new_key_bytes == 0) return;
            p.heap.ensureUnusedCapacity(gpa, new_key_bytes) catch return refusal(budget);
            p.spans.ensureUnusedCapacity(gpa, records) catch return refusal(budget);
            p.table.ensureUnusedCapacityContext(gpa, @intCast(records), .{ .pending = p }) catch return refusal(budget);
        }

        /// Room for `records` more records of an ordered index.
        pub fn reserveOrdered(p: *Self, budget: *Budget, records: usize) (Allocator.Error || BudgetError)!void {
            budget.refused = false;
            p.ordered.ensureUnusedCapacity(budget.allocator(), records) catch return refusal(budget);
        }

        /// The bytes `key` adds to the keys' heap: none when it is interned.
        pub fn newKeyBytes(p: *const Self, key: []const u8) usize {
            return if (p.table.containsAdapted(key, ByBytes{ .pending = p })) 0 else key.len;
        }

        /// A record whose exact key is `key` added, its key interned, what
        /// it grows charged to `budget`: `error.KeyTooLong` past
        /// `format.max_key_bytes`, `error.IndexMemory` when the budget would
        /// be passed. Nothing is added on an error. After a `reserveExact`
        /// that made room for it, it allocates nothing.
        pub fn addExact(p: *Self, budget: *Budget, key: []const u8, seq: Seq, offset: Bytes) (Allocator.Error || BudgetError || KeyError)!void {
            if (key.len > format.max_key_bytes) return error.KeyTooLong;
            const counted = try p.past(seq);
            const found = p.table.getKeyAdapted(key, ByBytes{ .pending = p });
            try p.reserveExact(budget, 1, if (found == null) key.len else 0);
            const number: u32 = found orelse number: {
                const n: u32 = @intCast(p.spans.items.len);
                p.spans.appendAssumeCapacity(.{ .at = @intCast(p.heap.items.len), .len = @intCast(key.len) });
                p.heap.appendSliceAssumeCapacity(key);
                p.table.putAssumeCapacityContext(n, {}, .{ .pending = p });
                break :number n;
            };
            p.exact.appendAssumeCapacity(.{ .key = number, .seq = counted, .offset = offset.raw() });
        }

        /// `seq` as a count past the segment's first: a segment of more than
        /// four billion records has no room in this index, and seals early.
        fn past(p: *const Self, seq: Seq) BudgetError!u32 {
            const gap = p.base.distanceTo(seq) catch return error.IndexMemory;
            return std.math.cast(u32, gap.raw()) orelse error.IndexMemory;
        }

        /// A record whose ordered key is `key` added, what it grows charged to
        /// `budget`.
        pub fn addOrdered(p: *Self, budget: *Budget, key: u64, seq: Seq, offset: Bytes) (Allocator.Error || BudgetError)!void {
            const counted = try p.past(seq);
            try p.reserveOrdered(budget, 1);
            p.ordered.appendAssumeCapacity(.{ .key = key, .seq = counted, .offset = offset.raw() });
        }

        /// The records `asked` asks for, past `after` and at most `through`,
        /// oldest first, into `out`.
        pub fn postings(p: *const Self, gpa: Allocator, asked: *const read.Asked, after: Seq, through: Seq, out: *std.ArrayList(format.Posting)) Allocator.Error!void {
            out.clearRetainingCapacity();
            switch (asked.*) {
                .none => {},
                .exact => {
                    const number = p.table.getKeyAdapted(asked.keyBytes(), ByBytes{ .pending = p }) orelse return;
                    for (p.exact.items) |posted| if (posted.key == number) try p.posting(gpa, posted.seq, posted.offset, after, through, out);
                },
                .ordered => for (p.ordered.items) |posted| if (asked.holdsWord(posted.key)) try p.posting(gpa, posted.seq, posted.offset, after, through, out),
            }
        }

        fn posting(p: *const Self, gpa: Allocator, counted: u32, offset: u64, after: Seq, through: Seq, out: *std.ArrayList(format.Posting)) Allocator.Error!void {
            const seq = p.base.advance(.fromRaw(counted)) catch aegis.assert.never("a record noted past the segment's first is a seq it was");
            if (seq.compare(after) != .gt or seq.compare(through) == .gt) return;
            try out.append(gpa, .{ .seq = seq, .offset = .fromRaw(offset), .extra = 0 });
        }

        /// How many records it holds.
        pub fn len(p: *const Self) usize {
            return p.exact.items.len + p.ordered.items.len;
        }

        /// The records past the first `kept` taken back: a batch staged and
        /// taken back. Keys they interned stay for the segment's later
        /// records, and the memory stays, charged.
        pub fn rollback(p: *Self, kept: usize) void {
            inline for (.{ &p.exact, &p.ordered }) |list| {
                if (kept < list.items.len) list.shrinkRetainingCapacity(kept);
            }
        }

        /// Every key and record dropped, to start the segment whose first
        /// record is `base`. The memory is kept, and stays charged: the next
        /// segment's records fill it before anything grows.
        pub fn clear(p: *Self, base: Seq) void {
            p.base = base;
            p.heap.clearRetainingCapacity();
            p.spans.clearRetainingCapacity();
            p.table.clearRetainingCapacity();
            p.exact.clearRetainingCapacity();
            p.ordered.clearRetainingCapacity();
        }

        /// Everything given back through `budget`, which charged it.
        pub fn deinit(p: *Self, budget: *Budget) void {
            const gpa = budget.allocator();
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

test "what the lists and table hold is charged as they grow, refused past the limit, kept charged when cleared, and given back at deinit" {
    var budget: Budget = .init(testing.allocator, values.furthest);
    var p: Pending = .{};
    p.clear(.fromRaw(1));
    try p.addExact(&budget, "a", .fromRaw(1), .fromRaw(0));
    try p.addExact(&budget, "a", .fromRaw(2), .fromRaw(10));
    try testing.expectEqual(1, p.spans.items.len);
    // What is charged is what the containers hold.
    const held = p.exact.capacity * @sizeOf(ExactPosted) + p.spans.capacity * @sizeOf(KeySpan) + p.heap.capacity;
    try testing.expect(values.limit(budget.used) >= held);
    // Past the limit a growth is refused, and nothing is added.
    budget.limit = budget.used;
    var record: usize = 3;
    const refused: ?anyerror = while (record < 10_000) : (record += 1) {
        p.addExact(&budget, "a", .fromRaw(record), .fromRaw(record * 10)) catch |err| break err;
    } else null;
    try testing.expectEqual(@as(?anyerror, error.IndexMemory), refused);
    try testing.expectEqual(record - 1, p.len());
    try testing.expect(budget.used.compare(budget.limit) != .gt);
    // Cleared, the storage stays and stays charged; the next segment fills it.
    const before = budget.used;
    p.clear(.fromRaw(record));
    try testing.expect(budget.used.eql(before));
    try p.addExact(&budget, "b", .fromRaw(record), .fromRaw(0));
    var long: [format.max_key_bytes + 1]u8 = @splat('k');
    try testing.expectError(error.KeyTooLong, p.addExact(&budget, &long, .fromRaw(record + 1), .fromRaw(30)));
    // A record before the segment's first has no place in its index.
    try testing.expectError(error.IndexMemory, p.addExact(&budget, "b", .fromRaw(record - 1), .fromRaw(30)));
    p.deinit(&budget);
    try testing.expect(budget.used.eql(values.no_bytes));
}

test "room made before a record is noted leaves the noting nothing to allocate" {
    var budget: Budget = .init(testing.allocator, values.furthest);
    var p: Pending = .{};
    defer p.deinit(&budget);
    p.clear(.fromRaw(1));
    try p.reserveExact(&budget, 3, p.newKeyBytes("abc") + p.newKeyBytes("de"));
    budget.limit = budget.used;
    try p.addExact(&budget, "abc", .fromRaw(1), .fromRaw(0));
    try p.addExact(&budget, "de", .fromRaw(2), .fromRaw(10));
    try p.addExact(&budget, "abc", .fromRaw(3), .fromRaw(20));
    try testing.expectEqual(0, p.newKeyBytes("abc"));
}

fn sameHash(_: []const u8) u64 {
    return 7;
}

test "keys sharing a hash are kept apart, and each record is filed under its own key at the seal" {
    const gpa = testing.allocator;
    var budget: Budget = .init(gpa, values.furthest);
    var p: PendingWith(sameHash) = .{};
    defer p.deinit(&budget);
    p.clear(.fromRaw(10));
    const keys = [_][]const u8{ "alpha", "beta", "alpha", "a key longer than eight bytes", "beta", "gamma" };
    for (keys, 0..) |k, i| try p.addExact(&budget, k, .fromRaw(10 + i), .fromRaw(i * 8));
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
    var budget: Budget = .init(gpa, values.furthest);
    var p: Pending = .{};
    defer p.deinit(&budget);
    p.clear(.fromRaw(5));
    try p.addOrdered(&budget, format.orderedKey(@as(i64, -3)), .fromRaw(5), .fromRaw(0));
    try p.addOrdered(&budget, format.orderedKey(@as(i64, 4)), .fromRaw(6), .fromRaw(9));
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

/// A million distinct keys of `key_len` bytes, a full default segment at a
/// time, through a budget of the default sizing: none refused, and the most
/// the allocator under it held, counted by it, within the budget.
fn millionKeys(kind: format.Kind, key_len: usize) !void {
    const segment_bytes: Bytes = .fromRaw(8 * 1024 * 1024);
    const limit = fullSegment(segment_bytes, kind, key_len);
    const per_segment = try segment_bytes.ratio(.fromRaw(smallest_record_bytes));
    // What the containers really hold, counted apart from the budget.
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var budget: Budget = .init(counting.allocator(), limit);
    var p: Pending = .{};
    defer p.deinit(&budget);
    var key: [format.max_key_bytes]u8 = @splat('k');
    for (0..1_000_000) |i| {
        // A segment seals when its records fill it.
        if (i % per_segment == 0) p.clear(.fromRaw(i + 1));
        std.mem.writeInt(u64, key[0..8], i, .little);
        switch (kind) {
            .exact => try p.addExact(&budget, key[0..key_len], .fromRaw(i + 1), .fromRaw(i * smallest_record_bytes)),
            .ordered => try p.addOrdered(&budget, i, .fromRaw(i + 1), .fromRaw(i * smallest_record_bytes)),
        }
    }
    try testing.expect(budget.most.compare(limit) != .gt);
    try testing.expectEqual(counting.allocated_bytes - counting.freed_bytes, values.limit(budget.used));
}

test "a million distinct u64 keys, a full default segment at a time, stay within the default index memory, every byte counted" {
    try millionKeys(.exact, 8);
}

test "a million distinct longest keys stay within the default index memory" {
    try millionKeys(.exact, format.max_key_bytes);
}

test "a million ordered keys stay within the default index memory" {
    try millionKeys(.ordered, 0);
}
