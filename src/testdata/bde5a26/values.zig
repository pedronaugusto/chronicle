//! The events in the journal beside this file, which chronicle bde5a26
//! wrote: its own writer, before chronicle wrote through strand. The suite
//! reads that journal with the chronicle of today and holds it to these
//! values, and appends them again and holds the bytes to the ones bde5a26
//! wrote (`journal_test.zig`, "a log written before strand ...").
//!
//! Every shape the old writer wrote itself or handed to `std.json`: strings
//! with escapes, controls, UTF-8 and bytes that are not, null optionals,
//! integers at their edges and past 64 bits, floats, enums with names that
//! need escaping, nested structs, arrays, a `std.json.Value`.
//!
//! How it was made: `generate.zig` here, built against chronicle bde5a26,
//! run as `generate <dir>`. It uses only `std`.

const std = @import("std");

pub const Hue = enum { red, @"gr\"een", blue };

pub const Event = union(enum) {
    created: struct { id: u32, name: []const u8 },
    note: struct { text: []const u8, by: ?[]const u8, tags: []const []const u8 },
    wide: struct { big: u128, small: i8, neg: i128, count: u64 },
    real: struct { x: f64, y: ?f32 },
    hue: Hue,
    nested: struct { a: ?u8, inner: struct { flag: bool, list: []const u32 }, fixed: [3]u16 },
    bytes: []const u8,
    empty,
    value: std.json.Value,
};

pub const count = 400;
/// Small segments, so the log crosses several and the chain is carried
/// across rotations.
pub const max_segment_bytes = 4096;

/// The `at` of record `i`, which the edges of an `i64` are among.
pub fn at(i: usize) i64 {
    return switch (i % 7) {
        0 => std.math.minInt(i64) + @as(i64, @intCast(i)),
        1 => std.math.maxInt(i64) - @as(i64, @intCast(i)),
        2 => -@as(i64, @intCast(i)),
        else => 1_700_000_000_000 + @as(i64, @intCast(i)) * 997,
    };
}

fn awkward(r: std.Random, buffer: []u8, utf8_only: bool) []const u8 {
    const pieces = [_][]const u8{
        "a",        "z",            " ",                "\"",                                   "\\", "\n", "\t", "\x00", "\x1f", "\x7f", "/",
        "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "abcdefghijklmnopqrstuvwxyz0123456789",
        "\xff", "\x80", "\xc3", // not UTF-8
    };
    const usable = if (utf8_only) pieces.len - 3 else pieces.len;
    var len: usize = 0;
    for (0..r.uintLessThan(usize, 10)) |_| {
        const pick = pieces[r.uintLessThan(usize, usable)];
        if (len + pick.len > buffer.len) break;
        @memcpy(buffer[len..][0..pick.len], pick);
        len += pick.len;
    }
    return buffer[0..len];
}

/// Record `i`'s event, on `a`.
pub fn event(a: std.mem.Allocator, r: std.Random, i: usize) !Event {
    const text = try a.dupe(u8, awkward(r, try a.alloc(u8, 120), true));
    return switch (i % 9) {
        0 => .{ .created = .{ .id = r.int(u32), .name = text } },
        1 => .{ .note = .{
            .text = text,
            .by = if (r.boolean()) try a.dupe(u8, awkward(r, try a.alloc(u8, 40), true)) else null,
            .tags = try a.dupe([]const u8, &.{ "one", text }),
        } },
        2 => .{ .wide = .{
            .big = switch (i % 4) {
                0 => std.math.maxInt(u128),
                else => r.int(u128) >> r.int(u7),
            },
            .small = r.int(i8),
            .neg = switch (i % 3) {
                0 => std.math.minInt(i128),
                else => r.int(i128) >> r.int(u7),
            },
            .count = if (i % 5 == 0) std.math.maxInt(u64) else r.int(u64) >> r.int(u6),
        } },
        3 => .{ .real = .{
            .x = @bitCast(r.int(u64) & 0x7fef_ffff_ffff_ffff),
            .y = if (r.boolean()) @as(f32, @floatFromInt(r.int(i16))) / 7.0 else null,
        } },
        4 => .{ .hue = r.enumValue(Hue) },
        5 => .{ .nested = .{
            .a = if (r.boolean()) r.int(u8) else null,
            .inner = .{ .flag = r.boolean(), .list = try a.dupe(u32, &.{ r.int(u32), 0, std.math.maxInt(u32) }) },
            .fixed = .{ r.int(u16), 0, 7 },
        } },
        6 => .{ .bytes = try a.dupe(u8, awkward(r, try a.alloc(u8, 60), false)) },
        7 => .empty,
        else => .{ .value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            a,
            try std.fmt.allocPrint(a, "{{\"k\":[1,2.5,null,true,\"{d}\"],\"n\":{{\"deep\":-{d}}}}}", .{ i, r.int(u32) }),
            .{},
        ) },
    };
}

/// Record `i` of the second journal, `chronicle.Journal(strand.Raw)`: an
/// event kept as its bytes, some with whitespace and line breaks between
/// their tokens, which a record writes as spaces.
pub fn raw(a: std.mem.Allocator, r: std.Random, i: usize) ![]const u8 {
    const text = awkward(r, try a.alloc(u8, 80), true);
    var escaped: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    return switch (i % 4) {
        0 => std.fmt.allocPrint(a, "{{\"node\":{d},\"body\":{{\"text\":{{\"content\":{s},\"done\":true}}}}}}", .{ i, escaped.written() }),
        1 => std.fmt.allocPrint(a, "{{ \"node\" : {d},\n  \"parent\": null,\r\n\t\"body\" : {{\"tool\":[1, 2.50, {s}]}} }}", .{ i, escaped.written() }),
        2 => std.fmt.allocPrint(a, "[{d},{s},{{}},[],\"caf\\u00e9\"]", .{ r.int(u64), escaped.written() }),
        else => std.fmt.allocPrint(a, "{s}", .{escaped.written()}),
    };
}

pub const raw_count = 120;

/// The generator the events come from.
pub fn generator() std.Random.DefaultPrng {
    return .init(0xb_de5a26);
}
