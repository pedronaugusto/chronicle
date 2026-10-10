//! The envelope against any bytes at all. A line comes off a disk, and
//! whatever is there is read by these functions before anything else has
//! looked at it: `trailer`, `quick`, `members`, `stamp`, `backLink` and
//! `batchOf` read one line the same way, whichever they read it by.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const envelope = @import("journal/envelope.zig");
const values = @import("journal/values.zig");
const Trailer = envelope.Trailer;
const Head = envelope.Head;
const Stamp = envelope.Stamp;
const Batch = envelope.Batch;
const trailer = envelope.trailer;
const quick = envelope.quick;
const members = envelope.members;
const stamp = envelope.stamp;
const backLink = envelope.backLink;
const batchOf = envelope.batchOf;

/// A line built from the pieces an envelope is made of, in any order and
/// with arbitrary bytes between them, so that a generated line lands near
/// the written shape as often as it lands far from it.
fn generateLine(s: *shakedown.Source, buf: []u8) []u8 {
    const pieces = [_][]const u8{
        "{\"seq\":",                               ",\"at\":", ",\"v\":",   ",\"p\":",             ",\"ev\":",            ",\"c\":",    "}",
        ",\"bf\":",                                ",\"bl\":", "{\"x\":1}", "[1,{\"y\":[]}]",      "\"s\\u0070\"",        "null",       " ",
        "-",                                       "0",        "00",        "9223372036854775807", "9223372036854775808", "4294967295", "4294967296",
        "{\"created\":{\"id\":1,\"name\":\"x\"}}", "\"p\":",   "\"seq\":",  "1.0",                 "1e3",
    };
    var end: usize = 0;
    while (s.more(24)) {
        var chunk: [24]u8 = undefined;
        const piece: []const u8 = switch (gen.intRange(s, u8, 0, 3)) {
            0 => gen.oneOf(s, []const u8, &pieces),
            1 => digits: {
                const n = gen.intRange(s, u8, 1, 20);
                for (chunk[0..n]) |*d| d.* = '0' + gen.intRange(s, u8, 0, 9);
                break :digits chunk[0..n];
            },
            2 => gen.oneOf(s, []const u8, pieces[0..9]),
            else => bytes: {
                const n = gen.intRange(s, usize, 0, chunk.len);
                s.bytes(chunk[0..n]);
                break :bytes chunk[0..n];
            },
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

fn fuzzEnvelope(_: void, case: *shakedown.Case) anyerror!void {
    var buf: [512]u8 = undefined;
    try checkEnvelope(generateLine(case.source, &buf));
}

test "a line's envelope reads the same off the bytes as by its members" {
    try shakedown.check(testing.allocator, {}, fuzzEnvelope, .{ .cases = 2000 });
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
}
