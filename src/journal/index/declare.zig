//! Field indexes as a journal's event declares them:
//!
//!     pub const chronicle = .{ .indexes = &.{
//!         index("account", 1, .exact, accountOf), // fn (Event) ?u64
//!         index("amount", 1, .ordered, amountOf), // fn (Event) ?i64
//!     } };
//!
//! Each names its index, its version (raised when the key function changes,
//! which makes every file of the old version stale), its kind, and its key:
//! a function of the event giving the record's key, or null for a record the
//! index does not hold. Everything is checked when the journal's type is
//! made, so a declaration that cannot work does not compile, and says which.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const format = @import("format.zig");
const read = @import("read.zig");

pub const Kind = format.Kind;

/// The name the stream index has: no declared index may take it.
pub const stream_index_name = "stream";

/// Whether an aegis scalar (an instant, an id) of type `T` keys an ordered
/// index: it gives its integer through `raw`.
fn rawInt(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "raw")) return null;
    const R = @typeInfo(@TypeOf(T.raw)).@"fn".return_type orelse return null;
    if (@typeInfo(R) != .int or @typeInfo(R).int.bits > 64) return null;
    return R;
}

fn checkKey(comptime kind: Kind, comptime name: []const u8, comptime T: type) void {
    const ok = switch (kind) {
        .exact => T == []const u8 or (@typeInfo(T) == .int and @typeInfo(T).int.bits <= 64) or @typeInfo(T) == .@"enum",
        .ordered => (@typeInfo(T) == .int and @typeInfo(T).int.bits <= 64) or rawInt(T) != null,
    };
    if (!ok) @compileError("chronicle: index \"" ++ name ++ "\": an " ++ @tagName(kind) ++ " index cannot be keyed by " ++ @typeName(T) ++
        if (kind == .exact) " (an exact key is []const u8, an integer of at most 64 bits, or an enum)" else " (an ordered key is an integer of at most 64 bits, or an aegis instant or id)");
}

/// One declared index, as `index` makes it.
pub fn Index(comptime name: []const u8, comptime version: u32, comptime kind: Kind, comptime key: anytype) type {
    if (!format.validName(name)) @compileError("chronicle: index \"" ++ name ++ "\": a name is 1 to 32 lower-case letters, digits and _, a letter first");
    if (std.mem.eql(u8, name, stream_index_name)) @compileError("chronicle: index \"stream\" is the stream index's name");
    const F = @TypeOf(key);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => @compileError("chronicle: index \"" ++ name ++ "\": its key is a function of the event, fn (Event) ?Key"),
    };
    if (info.param_types.len != 1 or info.param_types[0] == null) @compileError("chronicle: index \"" ++ name ++ "\": its key function takes the event alone");
    const Returned = info.return_type orelse @compileError("chronicle: index \"" ++ name ++ "\": its key function gives ?Key");
    const K = switch (@typeInfo(Returned)) {
        .optional => |o| o.child,
        else => @compileError("chronicle: index \"" ++ name ++ "\": its key function gives ?Key, null for a record without one"),
    };
    checkKey(kind, name, K);
    return struct {
        pub const index_name = name;
        pub const index_version = version;
        pub const index_kind = kind;
        pub const Event = info.param_types[0].?;
        pub const Key = K;
        pub const keyOf = key;
    };
}

/// An index declaration: see the file's comment.
pub fn index(comptime name: []const u8, comptime version: u32, comptime kind: Kind, comptime key: anytype) Index(name, version, kind, key) {
    return .{};
}

/// What `Event` declares: its indexes in order, each checked against the
/// others and against the event.
pub fn Declared(comptime Event: type) type {
    const list = if (@typeInfo(Event) != .@"struct" and @typeInfo(Event) != .@"union" and @typeInfo(Event) != .@"enum") .{} else if (!@hasDecl(Event, "chronicle")) .{} else if (@hasField(@TypeOf(Event.chronicle), "indexes")) Event.chronicle.indexes.* else .{};
    const n = list.len;
    var seen: [n][]const u8 = undefined;
    inline for (list, 0..) |decl, i| {
        const D = @TypeOf(decl);
        if (!@hasDecl(D, "index_name")) @compileError("chronicle: each of Event.chronicle.indexes is an index(name, version, kind, key)");
        if (D.Event != Event) @compileError("chronicle: index \"" ++ D.index_name ++ "\": its key function takes " ++ @typeName(D.Event) ++ ", not the journal's event");
        for (seen[0..i]) |other| if (std.mem.eql(u8, other, D.index_name)) @compileError("chronicle: index \"" ++ D.index_name ++ "\" is declared twice");
        seen[i] = D.index_name;
    }
    const final_names = seen;
    return struct {
        pub const count = n;
        pub const names: [n][]const u8 = final_names;

        pub fn kind(comptime i: usize) Kind {
            return @TypeOf(list[i]).index_kind;
        }

        pub fn version(comptime i: usize) u32 {
            return @TypeOf(list[i]).index_version;
        }

        /// The longest key index `i` can have, in bytes, for sizing its
        /// memory.
        pub fn longestKey(comptime i: usize) usize {
            const K = @TypeOf(list[i]).Key;
            if (K == []const u8) return format.max_key_bytes;
            if (@typeInfo(K) == .@"enum") {
                var longest: usize = 0;
                for (@typeInfo(K).@"enum".field_names) |field_name| longest = @max(longest, field_name.len);
                return longest;
            }
            return 8;
        }

        /// The place of the index named `name` among the declarations: a
        /// name not declared does not compile.
        pub fn indexOf(comptime name: []const u8) usize {
            inline for (final_names, 0..) |declared_name, i| if (comptime std.mem.eql(u8, declared_name, name)) return i;
            @compileError("chronicle: no index \"" ++ name ++ "\" is declared on " ++ @typeName(Event));
        }

        /// The key of the index named `name`: what its key function gives.
        pub fn KeyOf(comptime name: []const u8) type {
            return @TypeOf(list[comptime indexOf(name)]).Key;
        }

        /// What a read of the index named `name` by `key` asks: an ordered
        /// index read by one key asks for the range of that key alone.
        pub fn askedFor(comptime name: []const u8, key: KeyOf(name)) read.Asked {
            const D = @TypeOf(list[comptime indexOf(name)]);
            switch (D.index_kind) {
                .exact => {
                    var held: [8]u8 = undefined;
                    // A key too long for any record: none has it.
                    const bytes = exactBytes(D.Key, key, &held) catch return .none;
                    return .exactKey(bytes);
                },
                .ordered => {
                    const word = orderedWord(D.Key, key);
                    return .between(word, word);
                },
            }
        }

        /// What a read of the ordered index named `name` by the keys from
        /// `lo` to `hi`, both in, asks.
        pub fn askedBetween(comptime name: []const u8, lo: KeyOf(name), hi: KeyOf(name)) read.Asked {
            const D = @TypeOf(list[comptime indexOf(name)]);
            if (D.index_kind != .ordered) @compileError("chronicle: index \"" ++ name ++ "\" is exact: a range is read from an ordered index");
            return .between(orderedWord(D.Key, lo), orderedWord(D.Key, hi));
        }

        /// Whether `event` has a key in index `i` that `asked` asks for: the
        /// check a record found through an index passes before it is handed
        /// on, and the filter of a segment read whole.
        pub fn holds(event: *const Event, i: usize, asked: *const read.Asked) bool {
            inline for (0..n) |k| if (k == i) {
                const D = @TypeOf(list[k]);
                const found = D.keyOf(event.*) orelse return false;
                switch (D.index_kind) {
                    .exact => {
                        var held: [8]u8 = undefined;
                        const bytes = exactBytes(D.Key, found, &held) catch return false;
                        return asked.holdsBytes(bytes);
                    },
                    .ordered => return asked.holdsWord(orderedWord(D.Key, found)),
                }
            };
            return false;
        }

        /// One event's keys: for each index, whether it has one, and its key,
        /// an exact key's bytes (borrowed from the event, or held in `held`)
        /// or an ordered key's word.
        pub const Keys = struct {
            has: [n]bool = @splat(false),
            bytes: [n][]const u8 = @splat(""),
            words: [n]u64 = @splat(0),
            held: [n][8]u8 = undefined,
        };

        /// `event`'s keys into `keys`: `error.KeyTooLong` for an exact key
        /// past `format.max_key_bytes`.
        pub fn keysOf(event: *const Event, keys: *Keys) error{KeyTooLong}!void {
            inline for (0..n) |i| {
                const D = @TypeOf(list[i]);
                const found = D.keyOf(event.*);
                keys.has[i] = found != null;
                if (found) |k| switch (D.index_kind) {
                    .exact => keys.bytes[i] = try exactBytes(D.Key, k, &keys.held[i]),
                    .ordered => keys.words[i] = orderedWord(D.Key, k),
                };
            }
        }
    };
}

fn exactBytes(comptime K: type, k: K, held: *[8]u8) error{KeyTooLong}![]const u8 {
    if (K == []const u8) {
        if (k.len > format.max_key_bytes) return error.KeyTooLong;
        return k;
    }
    if (@typeInfo(K) == .@"enum") return @tagName(k);
    // An integer as its eight little-endian bytes, signed ones as their two's complement.
    const wide: u64 = if (@typeInfo(K).int.signedness == .signed) @bitCast(@as(i64, k)) else k;
    std.mem.writeInt(u64, held, wide, .little);
    return held;
}

fn orderedWord(comptime K: type, k: K) u64 {
    if (@typeInfo(K) == .int) return format.orderedKey(k);
    return format.orderedKey(k.raw());
}

const testing = std.testing;

const Sample = union(enum) {
    paid: struct { account: u64, amount: i64, note: []const u8 },
    closed: struct { account: u64 },

    pub const chronicle = .{ .indexes = &.{
        index("account", 1, .exact, accountOf),
        index("amount", 2, .ordered, amountOf),
        index("note", 1, .exact, noteOf),
        index("kind", 1, .exact, kindOf),
    } };

    fn accountOf(e: Sample) ?u64 {
        return switch (e) {
            inline else => |v| v.account,
        };
    }
    fn amountOf(e: Sample) ?i64 {
        return switch (e) {
            .paid => |p| p.amount,
            .closed => null,
        };
    }
    fn noteOf(e: Sample) ?[]const u8 {
        return switch (e) {
            .paid => |p| p.note,
            .closed => null,
        };
    }
    fn kindOf(e: Sample) ?std.meta.Tag(Sample) {
        return std.meta.activeTag(e);
    }
};

test "an event's declared indexes, in order, and its keys by each" {
    const D = Declared(Sample);
    try testing.expectEqual(4, D.count);
    try testing.expectEqualStrings("amount", D.names[1]);
    try testing.expectEqual(Kind.ordered, D.kind(1));
    try testing.expectEqual(2, D.version(1));
    try testing.expectEqual(format.max_key_bytes, D.longestKey(2));
    try testing.expectEqual(6, D.longestKey(3));
    var keys: D.Keys = .{};
    const paid: Sample = .{ .paid = .{ .account = 7, .amount = -3, .note = "rent" } };
    try D.keysOf(&paid, &keys);
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0, 0, 0, 0 }, keys.bytes[0]);
    try testing.expectEqual(format.orderedKey(@as(i64, -3)), keys.words[1]);
    try testing.expectEqualStrings("rent", keys.bytes[2]);
    try testing.expectEqualStrings("paid", keys.bytes[3]);
    const closed: Sample = .{ .closed = .{ .account = 9 } };
    try D.keysOf(&closed, &keys);
    try testing.expect(keys.has[0] and !keys.has[1] and !keys.has[2]);
    var long: [format.max_key_bytes + 1]u8 = @splat('x');
    const too_long: Sample = .{ .paid = .{ .account = 1, .amount = 0, .note = &long } };
    try testing.expectError(error.KeyTooLong, D.keysOf(&too_long, &keys));
}

test "a read names its index and asks by the index's own key type, and a record is checked by its key" {
    const D = Declared(Sample);
    try testing.expectEqual(i64, D.KeyOf("amount"));
    try testing.expectEqual(2, D.indexOf("note"));
    const paid: Sample = .{ .paid = .{ .account = 7, .amount = -3, .note = "rent" } };
    const closed: Sample = .{ .closed = .{ .account = 9 } };
    const nine = D.askedFor("account", 9);
    try testing.expect(D.holds(&closed, 0, &nine) and !D.holds(&paid, 0, &nine));
    const below_zero = D.askedBetween("amount", -5, 0);
    try testing.expect(D.holds(&paid, 1, &below_zero) and !D.holds(&closed, 1, &below_zero));
    const exactly = D.askedFor("amount", -3);
    try testing.expect(D.holds(&paid, 1, &exactly));
    try testing.expect(D.holds(&paid, 3, &D.askedFor("kind", .paid)));
    var long: [format.max_key_bytes + 1]u8 = @splat('x');
    try testing.expect(D.askedFor("note", &long) == .none);
}

test "an event without declarations has no indexes" {
    const Plain = union(enum) { a: u8 };
    try testing.expectEqual(0, Declared(Plain).count);
    try testing.expectEqual(0, Declared(u32).count);
}
