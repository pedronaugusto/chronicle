//! The kinds of number the journal keeps apart: where a record sits in the
//! sequence, how many bytes a file or a buffer holds, and how many records.
//!
//! All three are aegis types, so a sequence number cannot stand where a byte
//! count is wanted and a count of records cannot be added to a count of bytes.
//! aegis gives each its checked arithmetic and its conversions, and gives the
//! sequence an order and an equality. What it does not give yet are the
//! relations between the kinds: a sequence number moved by a count of
//! records, the count between two sequence numbers, and an order on bytes and
//! counts. They are written once, here, on top of aegis's checked integers;
//! docs/design.md says why each of the raw reads below is the one place that
//! needs it.
//!
//! This file is internal. `chronicle.zig` names the three types.

const std = @import("std");
const aegis = @import("aegis");

const Position = struct {};
const Record = struct {};

/// Where a record sits in the sequence. The first record of a journal that
/// has never been compacted is 1 and each one after it is the next; zero is
/// the place before the first record, which a reader that has finished
/// nothing stands at.
pub const Seq = aegis.id.Id(Position, u64);

/// A length or an offset in bytes: a segment, a buffer, a record's line.
pub const Bytes = aegis.units.Bytes(u64);

/// A number of records.
pub const Records = aegis.units.Count(Record, u64);

/// `bytes` as a length in memory. A size past what the address space can hold
/// is a size no allocation can satisfy.
pub fn memory(bytes: Bytes) error{OutOfMemory}!usize {
    return aegis.int.cast(usize, bytes.raw()) catch error.OutOfMemory;
}

/// A byte or record count as a limit on a length in memory: one past the
/// address space is no limit at all.
pub fn limit(count: anytype) usize {
    return aegis.int.cast(usize, count.raw()) catch std.math.maxInt(usize);
}

/// The largest length there is: what stands for "as far as the file goes".
pub const furthest: Bytes = .fromRaw(std.math.maxInt(u64));
pub const no_bytes: Bytes = .fromRaw(0);
pub const no_records: Records = .fromRaw(0);

/// The place before the first record: what `replay` and `subscribeFrom` take
/// to read everything the log holds.
pub const beginning: Seq = .fromRaw(0);

/// The first record of a journal that has never been compacted.
pub const first_record: Seq = .fromRaw(1);

/// The last sequence number a record can carry. A record's `seq` is written
/// as a JSON integer, and `std.json` and every reader of this format take
/// that as an `i64`.
pub const newest_possible: Seq = .fromRaw(std.math.maxInt(i64));

pub const SequenceError = error{SequenceExhausted};

/// The place right after `seq`, which for the very largest number is that
/// number again. A position, not a record number: it is what a walk expects
/// next, and what compares above everything it has passed.
pub fn following(seq: Seq) Seq {
    return .fromRaw(aegis.int.Saturating(u64).init(seq.raw()).add(1).raw());
}

/// The record after `seq`. `error.SequenceExhausted` past `newest_possible`.
pub fn successor(seq: Seq) SequenceError!Seq {
    return advance(seq, .fromRaw(1));
}

/// `seq` moved on by `records`. `error.SequenceExhausted` past `newest_possible`.
pub fn advance(seq: Seq, records: Records) SequenceError!Seq {
    const moved = aegis.int.Checked(u64).init(seq.raw()).add(records.raw()) catch return error.SequenceExhausted;
    if (moved.raw() > newest_possible.raw()) return error.SequenceExhausted;
    return .fromRaw(moved.raw());
}

/// How many records `first` through `last` are, both counted. `last` one
/// below `first` is none, which is what a segment holding nothing is. Null
/// for two numbers that cannot bound a run: `last` further behind than that,
/// or a run longer than a count can hold.
pub fn span(first: Seq, last: Seq) ?Records {
    const Checked = aegis.int.Checked(u64);
    switch (first.compare(last)) {
        .lt, .eq => {
            const gap = Checked.init(last.raw()).sub(first.raw()) catch return null;
            const counted = gap.add(1) catch return null;
            return .fromRaw(counted.raw());
        },
        .gt => {
            const behind = Checked.init(first.raw()).sub(last.raw()) catch return null;
            return if (behind.raw() == 1) .fromRaw(0) else null;
        },
    }
}

/// The last sequence number of `records` records that start at `first`: the
/// one below `first` for none. Null when it runs past `newest_possible`, which
/// is a count that does not belong to that start.
pub fn lastOf(first: Seq, records: Records) ?Seq {
    const Checked = aegis.int.Checked(u64);
    const end = Checked.init(first.raw()).add(records.raw()) catch return null;
    const last = end.sub(1) catch return null;
    if (last.raw() > newest_possible.raw()) return null;
    return .fromRaw(last.raw());
}

/// The position `records` records before `seq`, when that is a record's:
/// null if it would be zero or below.
pub fn back(seq: Seq, records: Records) ?Seq {
    const gone = aegis.int.Checked(u64).init(seq.raw()).sub(records.raw()) catch return null;
    if (gone.raw() == 0) return null;
    return .fromRaw(gone.raw());
}

/// The number before `seq`; null for zero, which has none.
pub fn predecessor(seq: Seq) ?Seq {
    const before = aegis.int.Checked(u64).init(seq.raw()).sub(1) catch return null;
    return .fromRaw(before.raw());
}

/// `a` and `b` together, for lengths, offsets and counts that belong to one
/// file or one segment, and so are far inside 64 bits. A sum that is not is a
/// broken invariant, which stops the program in every build.
pub fn plus(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a.add(b) catch @panic("a length or count of one segment passed 64 bits");
}

/// `a` less `b`, for the same quantities: `b` is never the larger.
pub fn minus(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a.sub(b) catch @panic("a length or offset of one segment fell below zero");
}

/// Where two values of one aegis scalar domain stand to each other.
pub fn order(a: anytype, b: @TypeOf(a)) std.math.Order {
    if (comptime @hasDecl(@TypeOf(a), "compare")) return a.compare(b);
    return std.math.order(a.raw(), b.raw());
}

/// `a` is below `b`.
pub fn below(a: anytype, b: @TypeOf(a)) bool {
    return order(a, b) == .lt;
}

/// `a` is at most `b`.
pub fn atMost(a: anytype, b: @TypeOf(a)) bool {
    return order(a, b) != .gt;
}

/// The smaller of two values of one aegis scalar domain.
pub fn lesser(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (below(b, a)) b else a;
}

/// The larger of two values of one aegis scalar domain.
pub fn greater(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (below(a, b)) b else a;
}
