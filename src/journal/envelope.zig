//! A record's envelope and a segment's first line, read off the bytes.
//!
//! This package writes both in one shape — `{"seq":…,"at":…,"v":…,"p":…,
//! "ev":…,"c":…}` and `{"chronicle":…,"base":…,"root":…}`, no whitespace,
//! members in that order — and every read of a record goes through its
//! envelope, so that shape is read here directly: its leading integers off
//! the bytes by strand (`leadingIntMembers`), and the checksum found from the
//! end of the line. A line in
//! any other shape, a record written by hand, has its members read by strand
//! as their bytes, and a member is an integer only when it is written as one
//! (`integerOf`), which is what a reader of this format has always taken.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const jsonl = @import("jsonl.zig");
const strand = jsonl.strand;
const values = @import("values.zig");

const Seq = values.Seq;

/// A line as it lies in a file: bytes nothing has read yet, which are a record,
/// a segment's first line or damage until one of the readers in this file or in
/// `Log.zig` has said which. Everything that comes off a disk is one of these,
/// and `parse` hands it to a reader whose answer is a refined value or a named
/// refusal.
pub const Unparsed = aegis.input.Untrusted([]const u8);

/// A member's value as an integer when it is one written as one — no
/// fraction, no exponent, not a string — and within an `i64`. Null for
/// anything else.
pub fn integerOf(value: strand.json.Raw) ?i64 {
    const bytes = value.bytes;
    if (bytes.len == 0 or !(bytes[0] == '-' or std.ascii.isDigit(bytes[0]))) return null;
    if (!std.json.isNumberFormattedLikeAnInteger(bytes)) return null;
    return std.fmt.parseInt(i64, bytes, 10) catch null;
}

/// What a record's checksum covers, and the checksum.
pub const Trailer = struct {
    /// Everything before the `,"c":<digits>}` the line ends with.
    covered: []const u8,
    c: u32,
};

/// The checksum is the last member of every record this package writes, so
/// it is found from the end. Null when the line does not end in one, a JSON
/// integer that fits a `u32`.
pub fn trailer(line: []const u8) ?Trailer {
    const opening = ",\"c\":";
    if (line.len < opening.len + 2 or line[line.len - 1] != '}') return null;
    var at = line.len - 1;
    while (at > 0 and std.ascii.isDigit(line[at - 1])) at -= 1;
    if (at == line.len - 1 or at < opening.len) return null;
    // A JSON integer: no zero in front of other digits.
    if (line[at] == '0' and at + 1 != line.len - 1) return null;
    if (!std.mem.eql(u8, line[at - opening.len .. at], opening)) return null;
    return .{
        .covered = line[0 .. at - opening.len],
        .c = std.fmt.parseInt(u32, line[at .. line.len - 1], 10) catch return null,
    };
}

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
    at: i64,
    v: u32,
    /// The checksum of the record before this one.
    p: u32,
    /// The atomic batch the record was written in, or null for one written
    /// on its own or in a group commit.
    batch: ?Batch = null,
    ev: Span,
};

/// The envelope of a record in exactly the shape this package writes, read
/// out of what its checksum covers. Null to say "read it as members".
pub fn quick(covered: []const u8) ?Head {
    const Envelope = struct { seq: i64, at: i64, v: u32, p: u32 };
    const read = strand.json.leadingIntMembers(Envelope, covered) orelse return null;
    if (read.value.seq < 1) return null;
    const seq = Seq.fromRaw(aegis.int.cast(u64, read.value.seq) catch return null);
    var at = read.end;
    var batch: ?Batch = null;
    const bf_prefix = ",\"bf\":";
    if (std.mem.startsWith(u8, covered[at..], bf_prefix)) {
        at += bf_prefix.len;
        const first = digitsAt(covered, &at) orelse return null;
        const bl_prefix = ",\"bl\":";
        if (!std.mem.startsWith(u8, covered[at..], bl_prefix)) return null;
        at += bl_prefix.len;
        const last = digitsAt(covered, &at) orelse return null;
        batch = checkedBatch(seq, first, last) orelse return null;
    }
    const ev_prefix = ",\"ev\":";
    if (!std.mem.startsWith(u8, covered[at..], ev_prefix)) return null;
    return .{
        .seq = seq,
        .at = read.value.at,
        .v = read.value.v,
        .p = read.value.p,
        .batch = batch,
        .ev = .{ .from = at + ev_prefix.len, .to = covered.len },
    };
}

/// A JSON integer of digits alone at `at.*`, which moves past it, or null.
fn digitsAt(bytes: []const u8, at: *usize) ?i64 {
    const from = at.*;
    var end = from;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
    if (end == from or (bytes[from] == '0' and end - from > 1)) return null;
    at.* = end;
    return std.fmt.parseInt(i64, bytes[from..end], 10) catch null;
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

/// The batch a line's record was written in, read as `quick` and `members`
/// read the envelope. Null for a record written on its own and for a line
/// that is not a record, which is not this question's to refuse.
pub fn batchOf(gpa: Allocator, line: []const u8) Allocator.Error!?Batch {
    if (trailer(line)) |t| {
        if (quick(t.covered)) |head| return head.batch;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const head = members(arena.allocator(), line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return null,
    };
    return head.batch;
}

/// The envelope of a record in some other shape — members in another
/// order, whitespace, a record written by hand — read as its members'
/// bytes. The event is found where it lies in `line`. `scratch` holds
/// whatever reading the members took. `error.Corrupt` when the line is not
/// a record.
pub fn members(scratch: Allocator, line: []const u8) error{ OutOfMemory, Corrupt }!Head {
    const Members = struct { seq: strand.json.Raw, at: strand.json.Raw, v: strand.json.Raw, p: strand.json.Raw, bf: ?strand.json.Raw = null, bl: ?strand.json.Raw = null, ev: strand.json.Raw };
    const found = strand.json.parseLeaky(Members, scratch, line, .{ .ignore_unknown_fields = true, .limits = jsonl.limits(line.len) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    const seq = integerOf(found.seq) orelse return error.Corrupt;
    if (seq < 1) return error.Corrupt;
    const number: Seq = .fromRaw(aegis.int.cast(u64, seq) catch return error.Corrupt);
    const from = @intFromPtr(found.ev.bytes.ptr) - @intFromPtr(line.ptr); // safe: parseLine without copy_strings hands back a view into line; numbers only
    aegis.assert.invariant(from <= line.len and found.ev.bytes.len <= line.len - from, "a member read without a copy is a view into the line it was read from");
    // Both members of a batch or neither, and one the record can be in.
    if ((found.bf == null) != (found.bl == null)) return error.Corrupt;
    const batch: ?Batch = if (found.bf) |bf| checkedBatch(
        number,
        integerOf(bf) orelse return error.Corrupt,
        integerOf(found.bl.?) orelse return error.Corrupt,
    ) orelse return error.Corrupt else null;
    return .{
        .seq = number,
        .batch = batch,
        .at = integerOf(found.at) orelse return error.Corrupt,
        .v = std.math.cast(u32, integerOf(found.v) orelse return error.Corrupt) orelse return error.Corrupt,
        .p = std.math.cast(u32, integerOf(found.p) orelse return error.Corrupt) orelse return error.Corrupt,
        .ev = .{ .from = from, .to = from + found.ev.bytes.len },
    };
}

/// What the segment layer reads of a line: where the record sits in the
/// sequence, and when the caller said it happened.
pub const Stamp = struct {
    seq: Seq,
    /// Null when the line carries no `at`, or one that is not an integer.
    at: ?i64,
};

/// A line's `seq` and `at`, or null when the line is not an object carrying
/// a sequence number at all. The shape this package writes begins
/// `{"seq":<digits>,"at":<digits>,` and is read off the bytes, since this
/// runs over every line of the active segment at every open; anything else
/// is read as members, on an arena over `gpa` that is gone when this
/// returns.
pub fn stamp(gpa: Allocator, line: []const u8) Allocator.Error!?Stamp {
    quick: {
        const read = strand.json.leadingIntMembers(struct { seq: i64, at: i64 }, line) orelse break :quick;
        // A record goes on past its stamp.
        if (line[read.end] != ',') break :quick;
        if (read.value.seq < 1) return null;
        return .{ .seq = .fromRaw(aegis.int.cast(u64, read.value.seq) catch return null), .at = read.value.at };
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Members = struct { seq: strand.json.Raw, at: strand.json.Raw = .{ .bytes = "null" } };
    const found = strand.json.parseLeaky(Members, arena.allocator(), line, .{ .ignore_unknown_fields = true, .limits = jsonl.limits(line.len) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const seq = integerOf(found.seq) orelse return null;
    if (seq < 1) return null;
    return .{ .seq = .fromRaw(aegis.int.cast(u64, seq) catch return null), .at = integerOf(found.at) };
}

/// The `p` a line carries: the checksum of the record before it. Read off
/// the bytes where the shape is the one this package writes, and as members
/// where it is not, on an arena over `gpa`.
pub fn backLink(gpa: Allocator, line: []const u8) Allocator.Error!?u32 {
    if (trailer(line)) |t| {
        if (quick(t.covered)) |head| return head.p;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const found = strand.json.parseLeaky(struct { p: strand.json.Raw }, arena.allocator(), line, .{ .ignore_unknown_fields = true, .limits = jsonl.limits(line.len) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return std.math.cast(u32, integerOf(found.p) orelse return null);
}

//=========================================================================
// Tests. The journal-level ones, over records in every shape, are in
// `journal_test.zig`.
//=========================================================================

const testing = std.testing;

test "the written shape and any other read as the same envelope" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const written = "{\"seq\":7,\"at\":-3,\"v\":2,\"p\":11,\"ev\":{\"x\":1},\"c\":42}";
    const t = trailer(written).?;
    try testing.expectEqual(@as(u32, 42), t.c);
    const head = quick(t.covered).?;
    try testing.expectEqual(Head{ .seq = .fromRaw(7), .at = -3, .v = 2, .p = 11, .ev = .{ .from = 35, .to = 42 } }, head);
    try testing.expectEqualStrings("{\"x\":1}", written[head.ev.from..head.ev.to]);

    // Reordered and spaced, the same envelope out of its members.
    const by_hand = "{ \"p\" : 11, \"ev\" : {\"x\":1}, \"v\":2, \"at\":-3, \"seq\":7, \"c\":42}";
    try testing.expectEqual(@as(?Head, null), quick(by_hand));
    const other = try members(a, by_hand);
    try testing.expectEqual(head.seq, other.seq);
    try testing.expectEqual(head.at, other.at);
    try testing.expectEqual(head.v, other.v);
    try testing.expectEqual(head.p, other.p);
    try testing.expectEqualStrings("{\"x\":1}", by_hand[other.ev.from..other.ev.to]);
    try testing.expectEqual(@as(?u32, 11), (try backLink(testing.allocator, by_hand)));
    try testing.expectEqual(@as(?u32, 11), (try backLink(testing.allocator, written)));
    try testing.expectEqual(Stamp{ .seq = Seq.fromRaw(7), .at = -3 }, (try stamp(testing.allocator, by_hand)).?);
    try testing.expectEqual(Stamp{ .seq = Seq.fromRaw(7), .at = -3 }, (try stamp(testing.allocator, written)).?);

    // An integer only when written as one, within an `i64`, and a sequence
    // number from 1.
    for ([_][]const u8{
        "{\"seq\":\"7\",\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":7.0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":7e0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":07,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":0,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":9223372036854775808,\"at\":1,\"v\":1,\"p\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":4294967296,\"p\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":-1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"ev\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":1,\"seq\":2}",
        "[1]",
    }) |line| {
        try testing.expectError(error.Corrupt, members(a, line));
    }
    // A zero in front of digits is not a JSON integer, off the bytes or not.
    try testing.expectEqual(@as(?Head, null), quick("{\"seq\":07,\"at\":1,\"v\":1,\"p\":1,\"ev\":1"));
    // A record whose `p` is inside its event as well as its envelope is read
    // for its envelope's.
    const shadowed = "{\"ev\":{\"q\":1,\"p\":99},\"seq\":1,\"at\":1,\"v\":1,\"p\":5,\"c\":3}";
    try testing.expectEqual(@as(?u32, 5), (try backLink(testing.allocator, shadowed)));
    // A timestamp that is not an integer is no timestamp, not a bad line.
    try testing.expectEqual(Stamp{ .seq = Seq.fromRaw(3), .at = null }, (try stamp(testing.allocator, "{\"at\":\"x\",\"seq\":3}")).?);
    try testing.expectEqual(@as(?Stamp, null), (try stamp(testing.allocator, "{\"seq\":0,\"at\":1,\"v\":1}")));
    try testing.expectEqual(@as(?Trailer, null), trailer("{\"seq\":1,\"c\":}"));
    try testing.expectEqual(@as(?Trailer, null), trailer("{\"seq\":1,\"c\":4294967296}"));
}

test "metadata probes preserve allocation failure instead of declaring bytes invalid" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const line = "{\"s\\u0065q\":1,\"at\":2,\"\\u0070\":3}";
    try testing.expectError(error.OutOfMemory, stamp(failing.allocator(), line));
    try testing.expectError(error.OutOfMemory, backLink(failing.allocator(), line));
}

//=========================================================================
// Any bytes at all. A line comes off a disk, and whatever is there is read
// by these functions before anything else has looked at it.
//=========================================================================

/// A line built from the pieces an envelope is made of, in any order and
/// with arbitrary bytes between them, so that a generated line lands near
/// the written shape as often as it lands far from it.
fn generateLine(smith: *testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{
        "{\"seq\":",                               ",\"at\":", ",\"v\":",   ",\"p\":",             ",\"ev\":",            ",\"c\":",    "}",
        ",\"bf\":",                                ",\"bl\":", "{\"x\":1}", "[1,{\"y\":[]}]",      "\"s\\u0070\"",        "null",       " ",
        "-",                                       "0",        "00",        "9223372036854775807", "9223372036854775808", "4294967295", "4294967296",
        "{\"created\":{\"id\":1,\"name\":\"x\"}}", "\"p\":",   "\"seq\":",  "1.0",                 "1e3",
    };
    var end: usize = 0;
    while (!smith.eos()) {
        var chunk: [24]u8 = undefined;
        const piece: []const u8 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => pieces[smith.index(pieces.len)],
            1 => digits: {
                const n = smith.valueRangeAtMost(u8, 1, 20);
                for (chunk[0..n]) |*d| d.* = '0' + smith.valueRangeAtMost(u8, 0, 9);
                break :digits chunk[0..n];
            },
            2 => pieces[smith.index(9)],
            else => chunk[0..smith.slice(&chunk)],
        };
        if (end + piece.len > buf.len) break;
        @memcpy(buf[end..][0..piece.len], piece);
        end += piece.len;
    }
    return buf[0..end];
}

/// What `trailer` promises, said the slow way: the line ends in `,"c":`, a
/// JSON integer that fits a `u32`, and `}`.
fn referenceTrailer(line: []const u8) ?Trailer {
    if (line.len == 0 or line[line.len - 1] != '}') return null;
    var start = line.len - 1;
    while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
    const digits = line[start .. line.len - 1];
    if (digits.len == 0 or (digits[0] == '0' and digits.len > 1)) return null;
    if (!std.mem.endsWith(u8, line[0..start], ",\"c\":")) return null;
    const c = std.fmt.parseInt(u32, digits, 10) catch return null;
    return .{ .covered = line[0 .. start - ",\"c\":".len], .c = c };
}

fn expectSameHead(expected: Head, expected_line: []const u8, actual: Head, actual_line: []const u8) !void {
    try testing.expectEqual(expected.seq, actual.seq);
    try testing.expectEqual(expected.at, actual.at);
    try testing.expectEqual(expected.v, actual.v);
    try testing.expectEqual(expected.p, actual.p);
    try testing.expectEqual(expected.batch, actual.batch);
    try testing.expectEqualStrings(expected_line[expected.ev.from..expected.ev.to], actual_line[actual.ev.from..actual.ev.to]);
}

fn checkEnvelope(line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = trailer(line);
    const expected_trailer = referenceTrailer(line);
    try testing.expectEqual(expected_trailer == null, t == null);
    if (t) |found| {
        try testing.expectEqual(expected_trailer.?.c, found.c);
        try testing.expectEqualStrings(expected_trailer.?.covered, found.covered);
    }

    const by_members: ?Head = members(a, line) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Corrupt => null,
    };
    const off_bytes: ?Head = if (t) |found| quick(found.covered) else null;

    // Off the bytes or as members, one line has one envelope: where both
    // read it they agree, and where the bytes are the written shape around
    // an event that is JSON, the members are there to be read.
    if (off_bytes) |head| {
        if (std.json.validate(a, line[head.ev.from..head.ev.to]) catch false) {
            try expectSameHead(head, line, by_members orelse return error.TestExpectedMembers, line);
        }
        try testing.expectEqual(@as(?u32, head.p), try backLink(testing.allocator, line));
    }
    if (by_members) |head| {
        if (off_bytes) |other| try expectSameHead(head, line, other, line);
        try testing.expectEqual(Stamp{ .seq = head.seq, .at = head.at }, (try stamp(testing.allocator, line)).?);
        try testing.expectEqual(@as(?u32, head.p), try backLink(testing.allocator, line));

        // And the envelope written back in the one shape this package
        // writes reads as itself off the bytes.
        const batch = if (head.batch) |b| try a.print(",\"bf\":{d},\"bl\":{d}", .{ b.first, b.last }) else "";
        const written = try a.print("{{\"seq\":{d},\"at\":{d},\"v\":{d},\"p\":{d}{s},\"ev\":{s},\"c\":{d}}}", .{
            head.seq, head.at, head.v, head.p, batch, line[head.ev.from..head.ev.to], if (t) |found| found.c else 7,
        });
        const again = quick(trailer(written).?.covered) orelse return error.TestExpectedQuick;
        try expectSameHead(head, line, again, written);
        try testing.expectEqual(head.batch, try batchOf(testing.allocator, line));
    }

    // `stamp` never reads past the line, whatever it holds, and a stamp is
    // a sequence number from 1.
    if (try stamp(testing.allocator, line)) |found| try testing.expect(values.below(values.beginning, found.seq));
}

fn fuzzEnvelope(_: void, smith: *testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    try checkEnvelope(generateLine(smith, &buf));
}

test "fuzz: a line's envelope reads the same off the bytes as by its members" {
    try testing.fuzz({}, fuzzEnvelope, .{});
}

test "the envelope properties hold on a table of awkward lines" {
    for ([_][]const u8{
        "",
        "}",
        ",\"c\":}",
        ",\"c\":1}",
        "{\"seq\":1,\"at\":1",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":1,\"c\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":{},\"c\":0}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":{},\"c\":4294967295}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":{},\"c\":01}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":1,\"seq\":2,\"c\":1}",
        "{\"seq\":1,\"at\":1,\"v\":1,\"p\":1,\"ev\":{\"p\":2},\"c\":1}",
        "{\"ev\":{\"p\":2},\"seq\":1,\"at\":1,\"v\":1,\"p\":3,\"c\":1}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"bl\":5,\"ev\":{},\"c\":1}",
        "{\"bl\":5,\"ev\":{},\"bf\":3,\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"c\":1}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":4,\"bl\":3,\"ev\":{},\"c\":1}",
    }) |line| try checkEnvelope(line);
    // Seeded rounds, so a plain `zig build test` goes past the table.
    var prng: std.Random.DefaultPrng = .init(0x656e76);
    var bytes: [256]u8 = undefined;
    var buf: [512]u8 = undefined;
    for (0..2000) |_| {
        for (&bytes) |*byte| byte.* = switch (prng.random().uintLessThan(u8, 10)) {
            0...6 => 0,
            7, 8 => prng.random().uintLessThan(u8, 24),
            else => prng.random().int(u8),
        };
        var smith: testing.Smith = .{ .in = &bytes };
        try checkEnvelope(generateLine(&smith, &buf));
    }
}

test "a record of an atomic batch names a batch it can be in" {
    const covered = "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"bl\":5,\"ev\":{}";
    const head = quick(covered).?;
    try testing.expectEqual(Batch{ .first = .fromRaw(3), .last = .fromRaw(5) }, head.batch.?);
    try testing.expectEqualStrings("{}", covered[head.ev.from..head.ev.to]);
    for ([_][]const u8{
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":5,\"bl\":6,\"ev\":{}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":1,\"bl\":3,\"ev\":{}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":0,\"bl\":4,\"ev\":{}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"ev\":{}",
        "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":03,\"bl\":5,\"ev\":{}",
    }) |bad| try testing.expectEqual(@as(?Head, null), quick(bad));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // As members, both or neither, and in range.
    try testing.expectEqual(Batch{ .first = Seq.fromRaw(3), .last = Seq.fromRaw(5) }, (try members(arena.allocator(), "{\"bl\":5,\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":3,\"ev\":{}}")).batch.?);
    try testing.expectError(error.Corrupt, members(arena.allocator(), "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bl\":5,\"ev\":{}}"));
    try testing.expectError(error.Corrupt, members(arena.allocator(), "{\"seq\":4,\"at\":1,\"v\":1,\"p\":2,\"bf\":5,\"bl\":9,\"ev\":{}}"));
}
