//! A record's envelope, read through its members.
//!
//! This package writes a record as `{"seq":…,"at":…,"v":…,"p":…,"ev":…,
//! "c":…}`, and reads one in any spelling JSON allows: the members in any
//! order, whitespace anywhere, names escaped. Every reader of a line — the
//! scan at open, a replay, a backup — reads it once through strand's member
//! iterator (`read`), which checks the line is one JSON object and hands
//! over the members this file names; what a caller needs of them is asked
//! of the `Fields` that come back. A member is an integer only when it is
//! written as one (`strand.json.intOf`).
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const jsonl = @import("jsonl.zig");
const strand = jsonl.strand;
const values = @import("values.zig");
const streams = @import("streams.zig");

const Seq = values.Seq;
const Time = values.Time;

pub const Unparsed = values.Unparsed;

/// A member's value as a `T` when it is an integer written as one — no
/// fraction, no exponent, not a string — that `T` holds. Null for anything
/// else.
pub fn integerOf(comptime T: type, value: []const u8) ?T {
    return strand.json.intOf(T, value);
}

/// What a record's checksum covers, the checksum, and what the next record
/// links back to.
pub const Trailer = struct {
    /// The bytes the checksum covers: the line up to the separator before
    /// `c` for a record, before `sc` for a removed record's stub.
    covered: []const u8,
    /// What the next record's `p` names: the record's `c`. A stub keeps the
    /// `c` of the record it stands for, so nothing after it changes.
    c: u32,
    /// What `covered` must sum to: `c` for a record, `sc` for a stub.
    sum: u32,
};

/// A record's place in its stream.
pub const InStream = struct {
    /// Borrowed from the line.
    stream: streams.Stream,
    /// Where the stream's id sits in the line, between its quotes.
    id: Span,
    version: streams.StreamVersion,
};

/// Where a record's event sits in its line, as a pair of offsets rather
/// than a slice: the line a record is built from may be a copy of the one
/// its envelope was read from.
pub const Span = struct { from: usize, to: usize };

/// The records an atomic batch wrote, which every one of them names: a
/// record with `first <= seq <= last`. A batch is never split across
/// segments, so a log that ends with a record of a batch whose `last` it does
/// not hold ends inside that batch, and the batch is dropped whole.
pub const Batch = struct {
    first: Seq,
    last: Seq,
};

/// A record's envelope: everything in its line but the event and the
/// checksum.
pub const Head = struct {
    /// From 1 to `maxInt(i64)`, which is as far as a record's `seq` is
    /// read as an integer.
    seq: Seq,
    at: Time,
    v: u32,
    /// The checksum of the record before this one.
    p: u32,
    /// The atomic batch the record was written in, or null for one written
    /// on its own or in a group commit.
    batch: ?Batch = null,
    /// Its stream, or null for a record in none.
    in_stream: ?InStream = null,
    /// Whether this is the stub of a record whose stream was truncated past
    /// it: its place in the sequence and in its stream, without its event.
    removed: bool = false,
    /// Where the event is; empty for a stub.
    ev: Span,
};

/// What the segment layer reads of a line: where the record sits in the
/// sequence, and when the caller said it happened.
pub const Stamp = struct {
    seq: Seq,
    /// Null when the line carries no `at`, or one that is not an integer.
    at: ?Time,
};

/// A line that is not one JSON object, or that gives a member this file
/// reads more than once: no record, whatever else it holds.
pub const NotRecord = error{NotRecord};

/// The members of a line this file reads, each as its value's bytes, and
/// where the checksum is.
pub const Fields = struct {
    seq: ?[]const u8 = null,
    at: ?[]const u8 = null,
    v: ?[]const u8 = null,
    p: ?[]const u8 = null,
    bf: ?[]const u8 = null,
    bl: ?[]const u8 = null,
    s: ?[]const u8 = null,
    sv: ?[]const u8 = null,
    x: ?[]const u8 = null,
    sc: ?[]const u8 = null,
    /// Where `s`'s value sits in the line, its quotes included.
    s_at: ?Span = null,
    ev: ?Span = null,
    /// The checksum when the object's last member is `c`, an integer that
    /// fits a `u32` (and, for a stub, the one before it `sc`); null when it
    /// is not, which no record this package writes is.
    trailer: ?Trailer = null,

    /// The envelope, or `error.Corrupt` when the line lacks a member a
    /// record carries or carries one that is not what it must be.
    pub fn head(fields: Fields) error{Corrupt}!Head {
        const seq = seqOf(fields.seq orelse return error.Corrupt) orelse return error.Corrupt;
        // Both members of a batch or neither, and one the record can be in.
        if ((fields.bf == null) != (fields.bl == null)) return error.Corrupt;
        const batch: ?Batch = if (fields.bf) |bf| checkedBatch(
            seq,
            integerOf(i64, bf) orelse return error.Corrupt,
            integerOf(i64, fields.bl.?) orelse return error.Corrupt,
        ) orelse return error.Corrupt else null;
        // Both members of a stream's place or neither.
        if ((fields.s == null) != (fields.sv == null)) return error.Corrupt;
        const in_stream: ?InStream = if (fields.s) |id| in: {
            const stream = streams.idOf(id) orelse return error.Corrupt;
            // An id has one spelling: its bytes, between two quotes.
            const value = fields.s_at orelse return error.Corrupt;
            break :in .{
                .stream = stream,
                .id = .{ .from = value.from + 1, .to = value.from + 1 + stream.bytes.len },
                .version = .fromRaw(versionOf(fields.sv.?) orelse return error.Corrupt),
            };
        } else null;
        // A stub is a stream's record with no event, and its `sc`; a record
        // has its event and no `sc`.
        const removed = fields.x != null;
        if (removed) {
            if (integerOf(u8, fields.x.?) != 1 or in_stream == null or fields.ev != null or fields.sc == null) return error.Corrupt;
        } else if (fields.sc != null) return error.Corrupt;
        return .{
            .seq = seq,
            .batch = batch,
            .in_stream = in_stream,
            .removed = removed,
            .at = .fromRaw(integerOf(i64, fields.at orelse return error.Corrupt) orelse return error.Corrupt),
            .v = integerOf(u32, fields.v orelse return error.Corrupt) orelse return error.Corrupt,
            .p = integerOf(u32, fields.p orelse return error.Corrupt) orelse return error.Corrupt,
            .ev = if (removed) .{ .from = 0, .to = 0 } else fields.ev orelse return error.Corrupt,
        };
    }

    /// The line's `seq` and `at`, or null when it carries no sequence
    /// number.
    pub fn stamp(fields: Fields) ?Stamp {
        const seq = seqOf(fields.seq orelse return null) orelse return null;
        return .{ .seq = seq, .at = if (fields.at) |at| if (integerOf(i64, at)) |ms| Time.fromRaw(ms) else null else null };
    }

    /// The `p` the line carries: the checksum of the record before it.
    pub fn backLink(fields: Fields) ?u32 {
        return integerOf(u32, fields.p orelse return null);
    }

    /// The batch the line's record was written in. Null for a record written
    /// on its own and for a line that is not a record, which is not this
    /// question's to refuse.
    pub fn batchOf(fields: Fields) ?Batch {
        const found = fields.head() catch return null;
        return found.batch;
    }
};

/// A stream version: an integer from 1 to `maxInt(i64)`.
fn versionOf(value: []const u8) ?u64 {
    const version = integerOf(i64, value) orelse return null;
    if (version < 1) return null;
    return aegis.int.cast(u64, version) catch null;
}

/// A sequence number: an integer from 1 to `maxInt(i64)`.
fn seqOf(value: []const u8) ?Seq {
    const seq = integerOf(i64, value) orelse return null;
    if (seq < 1) return null;
    return .fromRaw(aegis.int.cast(u64, seq) catch return null);
}

/// The members of `line` this file reads, through strand's member iterator,
/// once: the line is checked to be one JSON object, and a member named twice
/// is refused, as a parse of the record refuses one.
pub fn read(_: void, line: []const u8) NotRecord!Fields {
    var members: strand.json.Members = undefined;
    members.init(line, .{ .limits = .sized(line.len) });
    var fields: Fields = .{};
    var last: ?strand.json.Member = null;
    var before_last: ?strand.json.Member = null;
    var checksum = false;
    while (members.next() catch return error.NotRecord) |member| {
        before_last = last;
        last = member;
        const names = .{ "seq", "at", "v", "p", "bf", "bl", "s", "sv", "x", "sc" };
        const index = member.which(&(names ++ .{ "ev", "c" })) orelse continue;
        switch (index) {
            inline 0...names.len - 1 => |i| {
                const name = names[i];
                if (@field(fields, name) != null) return error.NotRecord;
                @field(fields, name) = member.value;
                if (comptime std.mem.eql(u8, name, "s")) fields.s_at = .{ .from = member.value_start, .to = member.valueEnd() };
            },
            names.len => {
                if (fields.ev != null) return error.NotRecord;
                fields.ev = .{ .from = member.value_start, .to = member.valueEnd() };
            },
            else => {
                if (checksum) return error.NotRecord;
                checksum = true;
            },
        }
    }
    _ = members.finish() catch return error.NotRecord;
    if (last) |member| if (member.is("c")) {
        if (integerOf(u32, member.value)) |c| {
            // A stub's own checksum is the member before its `c`, and covers
            // everything before it.
            if (fields.x != null) {
                if (before_last) |sc| if (sc.is("sc")) {
                    if (integerOf(u32, sc.value)) |sum| fields.trailer = .{ .covered = line[0..sc.separator], .c = c, .sum = sum };
                };
            } else fields.trailer = .{ .covered = line[0..member.separator], .c = c, .sum = c };
        }
    };
    return fields;
}

/// The batch a record of sequence number `seq` names, when it is one that
/// record can be in.
fn checkedBatch(seq: Seq, first: i64, last: i64) ?Batch {
    if (first < 1 or last < 1) return null;
    const batch: Batch = .{
        .first = .fromRaw(aegis.int.cast(u64, first) catch return null),
        .last = .fromRaw(aegis.int.cast(u64, last) catch return null),
    };
    if (batch.first.compare(seq) == .gt or seq.compare(batch.last) == .gt) return null;
    return batch;
}

//=========================================================================
// Tests. The journal-level ones, over records in every shape, are in
// `journal_test.zig`.
//=========================================================================

const testing = std.testing;

fn headOf(line: []const u8) error{ NotRecord, Corrupt }!Head {
    return (try read({}, line)).head();
}

test "a line in any spelling reads as the same envelope" {
    const written = "{\"seq\":7,\"at\":-3,\"v\":2,\"p\":11,\"ev\":{\"x\":1},\"c\":42}";
    const fields = try read({}, written);
    try testing.expectEqual(@as(u32, 42), fields.trailer.?.c);
    try testing.expectEqualStrings("{\"seq\":7,\"at\":-3,\"v\":2,\"p\":11,\"ev\":{\"x\":1}", fields.trailer.?.covered);
    const head = try fields.head();
    try testing.expectEqual(Head{ .seq = .fromRaw(7), .at = .fromRaw(-3), .v = 2, .p = 11, .ev = .{ .from = 35, .to = 42 } }, head);
    try testing.expectEqualStrings("{\"x\":1}", written[head.ev.from..head.ev.to]);

    // Reordered, spaced and escaped, the same envelope.
    const by_hand = "{ \"p\" : 11, \"ev\" : {\"x\":1}, \"v\":2, \"\\u0061t\":-3, \"seq\":7 , \"c\" : 42 }\t";
    const other_fields = try read({}, by_hand);
    const other = try other_fields.head();
    try testing.expectEqual(head.seq, other.seq);
    try testing.expectEqual(head.at, other.at);
    try testing.expectEqual(head.v, other.v);
    try testing.expectEqual(head.p, other.p);
    try testing.expectEqualStrings("{\"x\":1}", by_hand[other.ev.from..other.ev.to]);
    try testing.expectEqualStrings("{ \"p\" : 11, \"ev\" : {\"x\":1}, \"v\":2, \"\\u0061t\":-3, \"seq\":7 ", other_fields.trailer.?.covered);
    try testing.expectEqual(@as(?u32, 11), other_fields.backLink());
    try testing.expectEqual(Stamp{ .seq = Seq.fromRaw(7), .at = .fromRaw(-3) }, other_fields.stamp().?);

    // An integer only when written as one, within an `i64`, and a sequence
    // number from 1.
    for ([_][]const u8{
        "{\"seq\":\"7\",\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":7.0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":7e0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":9223372036854775808,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":4294967296,\"p\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":-1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":1}",
    }) |line| try testing.expectError(error.Corrupt, headOf(line));
    // Not a record at all: not JSON, not an object, a member given twice.
    for ([_][]const u8{
        "{\"seq\":07,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":1,\"seq\":2}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":1,\"s\\u0065q\":2}",
        "{\"seq\":1,\"c\":1,\"ev\":1,\"c\":1}",
        "{\"seq\":1,\"at\":1",
        "{\"seq\":1} x",
        "[1]",
    }) |line| try testing.expectError(error.NotRecord, headOf(line));
    // A record whose `p` is inside its event as well as its envelope is read
    // for its envelope's.
    const shadowed = try read({}, "{\"ev\":{\"q\":1,\"p\":99},\"seq\":1,\"at\":1,\"v\":1,\"p\":5,\"c\":3}");
    try testing.expectEqual(@as(?u32, 5), shadowed.backLink());
    // A timestamp that is not an integer is no timestamp, not a bad line.
    try testing.expectEqual(Stamp{ .seq = Seq.fromRaw(3), .at = null }, (try read({}, "{\"at\":\"x\",\"seq\":3}")).stamp().?);
    try testing.expectEqual(@as(?Stamp, null), (try read({}, "{\"seq\":0,\"at\":1,\"v\":1}")).stamp());
    // A checksum only as the last member, an integer that fits a `u32`.
    try testing.expectEqual(@as(?Trailer, null), (try read({}, "{\"c\":1,\"seq\":1}")).trailer);
    try testing.expectEqual(@as(?Trailer, null), (try read({}, "{\"seq\":1,\"c\":4294967296}")).trailer);
    try testing.expectEqual(@as(?Trailer, null), (try read({}, "{\"seq\":1,\"c\":-1}")).trailer);
    // Alone, it covers nothing: there is nothing before the brace.
    try testing.expectEqualStrings("", (try read({}, "{\"c\":0}")).trailer.?.covered);
}

test "a record of an atomic batch names a batch it can be in" {
    const line = "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"bl\":5,\"ev\":{},\"c\":1}";
    const head = try headOf(line);
    try testing.expectEqual(Batch{ .first = .fromRaw(3), .last = .fromRaw(5) }, head.batch.?);
    try testing.expectEqualStrings("{}", line[head.ev.from..head.ev.to]);
    try testing.expectEqual(Batch{ .first = Seq.fromRaw(3), .last = Seq.fromRaw(5) }, (try headOf("{\"bl\":5,\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"ev\":{}}")).batch.?);
    for ([_][]const u8{
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":5,\"bl\":6,\"ev\":{}}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":1,\"bl\":3,\"ev\":{}}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":0,\"bl\":4,\"ev\":{}}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"ev\":{}}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bl\":5,\"ev\":{}}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":5,\"bl\":9,\"ev\":{}}",
    }) |bad| {
        try testing.expectError(error.Corrupt, headOf(bad));
        try testing.expectEqual(@as(?Batch, null), (try read({}, bad)).batchOf());
    }
}
