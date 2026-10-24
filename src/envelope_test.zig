//! The envelope against any bytes at all. A line comes off a disk, and
//! whatever is there is read by `envelope.read` before anything else has
//! looked at it: here it is held to what strand's parser makes of the same
//! line, whatever the line holds and however it is spelled.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const strand = @import("journal/jsonl.zig").strand;
const json = strand.json;
const envelope = @import("journal/envelope.zig");
const values = @import("journal/values.zig");
const read = envelope.read;

/// A line built from the pieces an envelope is made of, in any order and
/// with arbitrary bytes between them, so that a generated line lands near
/// the written shape as often as it lands far from it.
fn generateLine(s: *shakedown.Source, buf: []u8) []u8 {
    const pieces = [_][]const u8{
        "{\"seq\":",           ",\"at\":",   ",\"v\":",    ",\"p\":",                                 ",\"ev\":", ",\"c\":",   "}",
        " , \"s\\u0065q\" : ", "\t",         ",\"c\" :",   ",\"bf\":",                                ",\"bl\":", "{\"x\":1}", "[1,{\"y\":[]}]",
        "\"s\\u0070\"",        "null",       " ",          "-",                                       "0",        "00",        "9223372036854775807",
        "9223372036854775808", "4294967295", "4294967296", "{\"created\":{\"id\":1,\"name\":\"x\"}}", "\"p\":",   "\"seq\":",  "1.0",
        "1e3",
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

const names = [_][]const u8{ "seq", "at", "v", "p", "bf", "bl", "ev", "c" };

/// What `read` promises, said through the parser: a line is a record's
/// members exactly where it is one JSON object naming none of the envelope's
/// members twice, each member is the value the parser reads, and the
/// checksum is the last member when it is `c`, covering the line up to the
/// comma before it.
fn checkEnvelope(line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const any: json.ParseOptions = .{ .duplicates = null };
    const fields = read({}, line);
    const parsed = json.parseLeaky(json.Value, a, line, any) catch {
        try testing.expectError(error.NotRecord, fields);
        return;
    };
    if (parsed != .object) return testing.expectError(error.NotRecord, fields);
    const members = parsed.object;
    inline for (names) |name| {
        var count: usize = 0;
        for (members) |member| {
            if (std.mem.eql(u8, member.key, name)) count += 1;
        }
        if (count > 1) return testing.expectError(error.NotRecord, fields);
    }
    const found = try fields;
    for (members) |member| inline for (names[0..6]) |name| if (std.mem.eql(u8, member.key, name)) {
        try testing.expectEqualDeep(member.value, try json.parseLeaky(json.Value, a, @field(found, name).?, any));
    };
    for (members) |member| if (std.mem.eql(u8, member.key, "ev")) {
        try testing.expectEqualDeep(member.value, try json.parseLeaky(json.Value, a, line[found.ev.?.from..found.ev.?.to], any));
    };
    const last = if (members.len == 0) null else members[members.len - 1];
    const closes = last != null and std.mem.eql(u8, last.?.key, "c") and last.?.value == .number and json.intOf(u32, last.?.value.number) != null;
    try testing.expectEqual(closes, found.trailer != null);
    if (found.trailer) |t| {
        try testing.expectEqual(json.intOf(u32, last.?.value.number).?, t.c);
        // Everything the object holds before `c`, and the comma after it.
        try testing.expect(line.ptr == t.covered.ptr and t.covered.len < line.len);
        try testing.expect(line[t.covered.len] == ',' or (members.len == 1 and line[t.covered.len] == '{'));
    }

    // A stamp is a sequence number from 1.
    if (found.stamp()) |stamp| try testing.expect(values.below(values.beginning, stamp.seq));

    // And the envelope written back in the one shape this package writes
    // reads as itself.
    const head = found.head() catch return;
    const batch = if (head.batch) |b| try a.print(",\"bf\":{d},\"bl\":{d}", .{ b.first, b.last }) else "";
    const prefix = try a.print("{{\"seq\":{d},\"at\":{d},\"v\":{d},\"p\":{d}{s},\"ev\":{s}", .{
        head.seq, head.at, head.v, head.p, batch, line[head.ev.from..head.ev.to],
    });
    const written = try a.print("{s},\"c\":{d}}}", .{ prefix, if (found.trailer) |t| t.c else 7 });
    const again = try read({}, written);
    const other = try again.head();
    try testing.expectEqual(head.seq, other.seq);
    try testing.expectEqual(head.at, other.at);
    try testing.expectEqual(head.v, other.v);
    try testing.expectEqual(head.p, other.p);
    try testing.expectEqual(head.batch, other.batch);
    try testing.expectEqualStrings(line[head.ev.from..head.ev.to], written[other.ev.from..other.ev.to]);
    try testing.expectEqualStrings(prefix, again.trailer.?.covered);
    try testing.expectEqual(head.batch, again.batchOf());
    try testing.expectEqual(@as(?u32, head.p), again.backLink());
}

fn fuzzEnvelope(_: void, case: *shakedown.Case) anyerror!void {
    var buf: [512]u8 = undefined;
    try checkEnvelope(generateLine(case.source, &buf));
}

test "fuzz: a line's envelope is what the parser reads in it" {
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
        " { \"s\\u0065q\" : 1 , \"at\":1,\"v\":1,\"p\":1,\"ev\":[] , \"c\" : 9 } ",
        "{\"c\":1}",
    }) |line| try checkEnvelope(line);
}
