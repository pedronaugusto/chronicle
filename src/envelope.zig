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
const Allocator = std.mem.Allocator;
const strand = @import("jsonl.zig").strand;

/// A member's value as an integer when it is one written as one — no
/// fraction, no exponent, not a string — and within an `i64`. Null for
/// anything else.
pub fn integerOf(value: strand.Raw) ?i64 {
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
/// it is found from the end. Null when the line does not end in one.
pub fn trailer(line: []const u8) ?Trailer {
    const opening = ",\"c\":";
    if (line.len < opening.len + 2 or line[line.len - 1] != '}') return null;
    var at = line.len - 1;
    while (at > 0 and std.ascii.isDigit(line[at - 1])) at -= 1;
    if (at == line.len - 1 or at < opening.len) return null;
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

/// A record's envelope: everything in its line but the event and the
/// checksum.
pub const Head = struct {
    /// From 1 to `maxInt(i64)`, which is as far as a record's `seq` is
    /// read as an integer.
    seq: u64,
    at: i64,
    v: u32,
    /// The checksum of the record before this one.
    p: u32,
    ev: Span,
};

/// The envelope of a record in exactly the shape this package writes, read
/// out of what its checksum covers. Null to say "read it as members".
pub fn quick(covered: []const u8) ?Head {
    const Envelope = struct { seq: i64, at: i64, v: u32, p: u32 };
    const read = strand.leadingIntMembers(Envelope, covered) orelse return null;
    const ev_prefix = ",\"ev\":";
    if (!std.mem.startsWith(u8, covered[read.end..], ev_prefix)) return null;
    if (read.value.seq < 1) return null;
    return .{
        .seq = @intCast(read.value.seq),
        .at = read.value.at,
        .v = read.value.v,
        .p = read.value.p,
        .ev = .{ .from = read.end + ev_prefix.len, .to = covered.len },
    };
}

/// The envelope of a record in some other shape — members in another
/// order, whitespace, a record written by hand — read as its members'
/// bytes. The event is found where it lies in `line`. `scratch` holds
/// whatever reading the members took. `error.Corrupt` when the line is not
/// a record.
pub fn members(scratch: Allocator, line: []const u8) error{ OutOfMemory, Corrupt }!Head {
    const Members = struct { seq: strand.Raw, at: strand.Raw, v: strand.Raw, p: strand.Raw, ev: strand.Raw };
    const found = strand.parseLine(Members, scratch, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    const seq = integerOf(found.seq) orelse return error.Corrupt;
    if (seq < 1) return error.Corrupt;
    const from = @intFromPtr(found.ev.bytes.ptr) - @intFromPtr(line.ptr); // safe: parseLine without copy_strings hands back a view into line; numbers only
    return .{
        .seq = @intCast(seq),
        .at = integerOf(found.at) orelse return error.Corrupt,
        .v = std.math.cast(u32, integerOf(found.v) orelse return error.Corrupt) orelse return error.Corrupt,
        .p = std.math.cast(u32, integerOf(found.p) orelse return error.Corrupt) orelse return error.Corrupt,
        .ev = .{ .from = from, .to = from + found.ev.bytes.len },
    };
}

/// What the segment layer reads of a line: where the record sits in the
/// sequence, and when the caller said it happened.
pub const Stamp = struct {
    seq: u64,
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
        const read = strand.leadingIntMembers(struct { seq: i64, at: i64 }, line) orelse break :quick;
        // A record goes on past its stamp.
        if (line[read.end] != ',') break :quick;
        if (read.value.seq < 1) return null;
        return .{ .seq = @intCast(read.value.seq), .at = read.value.at };
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Members = struct { seq: strand.Raw, at: strand.Raw = .null };
    const found = strand.parseLine(Members, arena.allocator(), line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const seq = integerOf(found.seq) orelse return null;
    if (seq < 1) return null;
    return .{ .seq = @intCast(seq), .at = integerOf(found.at) };
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
    const found = strand.parseLine(struct { p: strand.Raw }, arena.allocator(), line, .{}) catch |err| switch (err) {
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
    try testing.expectEqual(Head{ .seq = 7, .at = -3, .v = 2, .p = 11, .ev = .{ .from = 35, .to = 42 } }, head);
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
    try testing.expectEqual(Stamp{ .seq = 7, .at = -3 }, (try stamp(testing.allocator, by_hand)).?);
    try testing.expectEqual(Stamp{ .seq = 7, .at = -3 }, (try stamp(testing.allocator, written)).?);

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
    try testing.expectEqual(Stamp{ .seq = 3, .at = null }, (try stamp(testing.allocator, "{\"at\":\"x\",\"seq\":3}")).?);
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
