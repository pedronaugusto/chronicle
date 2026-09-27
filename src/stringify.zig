//! An event, written as the JSON `std.json.Stringify.value(event, .{}, w)`
//! writes for it, byte for byte, in less time.
//!
//! What `std.json` spends an append on is its string escape, which looks at
//! one byte at a time, and the member names, which it escapes again for
//! every value although they are known when the program is compiled. Here a
//! string is scanned sixteen bytes at a time for the three things JSON has
//! to escape, and a struct's member names, a union's tag names and an enum's
//! value names are written as the constants they are.
//!
//! The shapes it writes itself are the ones an event is made of: structs,
//! tagged unions, exhaustive enums, optionals, integers, booleans, strings,
//! and slices, arrays and pointers of those. Anything else — a float, a
//! `std.json.Value`, a type with its own `jsonStringify`, a tuple, a string
//! that is not UTF-8 — is handed to `std.json` as it stands, so its bytes are
//! `std.json`'s by construction. The suite holds the rest to `std.json`
//! with a differential property and a fuzz target.
//!
//! The members in front of the event — sequence number, timestamp, version,
//! back-link — are written here too, as the digits they are, into a buffer
//! on the stack.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const Writer = std.Io.Writer;

/// Write `v` as `std.json.Stringify.value(v, .{}, w)` would.
pub fn value(v: anytype, w: *Writer) Writer.Error!void {
    const T = @TypeOf(v);
    if (comptime !written_here(T)) return std.json.Stringify.value(v, .{}, w);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (v) "true" else "false"),
        .int => try w.print("{d}", .{v}),
        .optional => if (v) |payload| try value(payload, w) else try w.writeAll("null"),
        .@"enum" => switch (v) {
            inline else => |tag| try w.writeAll(comptime quoted(@tagName(tag))),
        },
        .@"union" => switch (v) {
            inline else => |payload, tag| {
                try w.writeAll(comptime "{" ++ quoted(@tagName(tag)) ++ ":");
                if (@TypeOf(payload) == void) try w.writeAll("{}") else try value(payload, w);
                try w.writeByte('}');
            },
        },
        .@"struct" => |info| {
            try w.writeByte('{');
            comptime var first = true;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                try w.writeAll(comptime (if (first) "" else ",") ++ quoted(field.name) ++ ":");
                first = false;
                try value(@field(v, field.name), w);
            }
            try w.writeByte('}');
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => try value(@as([]const std.meta.Elem(info.child), v), w),
                else => try value(v.*, w),
            },
            .slice => if (info.child == u8) try string(v, w) else {
                try w.writeByte('[');
                for (v, 0..) |item, i| {
                    if (i != 0) try w.writeByte(',');
                    try value(item, w);
                }
                try w.writeByte(']');
            },
            else => unreachable,
        },
        .array => try value(@as([]const std.meta.Elem(T), &v), w),
        else => unreachable,
    }
}

/// The longest a record's line can be before its event:
/// `{"seq":<u64>,"at":<i64>,"v":<u32>,"p":<u32>,"ev":`.
pub const envelope_head_max = "{\"seq\":".len + 20 + ",\"at\":".len + 20 +
    ",\"v\":".len + 10 + ",\"p\":".len + 10 + ",\"ev\":".len;

/// A record's line up to its event, written into `buffer`: the bytes
/// `std.json` writes for those members of a `Line`, digit for digit, put
/// together without going through a format string.
pub fn envelopeHead(buffer: *[envelope_head_max]u8, seq: u64, at: i64, version: u32, back_link: u32) []const u8 {
    var end: usize = 0;
    inline for (.{
        .{ "{\"seq\":", seq },
        .{ ",\"at\":", at },
        .{ ",\"v\":", version },
        .{ ",\"p\":", back_link },
    }) |member| {
        @memcpy(buffer[end..][0..member[0].len], member[0]);
        end += member[0].len;
        end += decimal(buffer[end..], member[1]);
    }
    @memcpy(buffer[end..][0..",\"ev\":".len], ",\"ev\":");
    return buffer[0 .. end + ",\"ev\":".len];
}

/// `number` in base ten at the start of `out`, as `{d}` prints it; returns
/// how many bytes that took.
fn decimal(out: []u8, number: anytype) usize {
    var digits: [20]u8 = undefined;
    var at: usize = digits.len;
    var rest: u64 = @abs(number);
    while (rest >= 100) : (rest /= 100) {
        at -= 2;
        digits[at..][0..2].* = std.fmt.digits2(@intCast(rest % 100));
    }
    if (rest >= 10) {
        at -= 2;
        digits[at..][0..2].* = std.fmt.digits2(@intCast(rest));
    } else {
        at -= 1;
        digits[at] = '0' + @as(u8, @intCast(rest));
    }
    var end: usize = 0;
    if (number < 0) {
        out[0] = '-';
        end = 1;
    }
    const written = digits[at..];
    @memcpy(out[end..][0..written.len], written);
    return end + written.len;
}

/// Whether `value` writes a `T` itself rather than handing it to
/// `std.json`. It answers for the outermost shape only; what is inside is
/// asked again when it is written, so a type that contains itself is fine.
fn written_here(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .optional, .array => true,
        .@"enum" => |info| info.is_exhaustive and !std.meta.hasFn(T, "jsonStringify"),
        .@"union" => |info| info.tag_type != null and !std.meta.hasFn(T, "jsonStringify"),
        .@"struct" => |info| !info.is_tuple and !std.meta.hasFn(T, "jsonStringify"),
        .pointer => |info| info.size == .one or info.size == .slice,
        else => false,
    };
}

/// A name as `std.json` writes it: a JSON string, escaped.
fn quoted(comptime name: []const u8) []const u8 {
    comptime {
        var buffer: [2 + 6 * name.len]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        std.json.Stringify.encodeJsonString(name, .{}, &w) catch unreachable;
        const frozen = buffer[0..w.end].*;
        return &frozen;
    }
}

/// A byte string as `std.json` writes one: a JSON string when it is UTF-8,
/// escaping only what JSON requires, and whatever `std.json` makes of it
/// when it is not.
fn string(s: []const u8, w: *Writer) Writer.Error!void {
    if (!std.unicode.utf8ValidateSlice(s)) return std.json.Stringify.value(s, .{}, w);
    try w.writeByte('"');
    var from: usize = 0;
    var at: usize = 0;
    while (true) {
        at = clean(s, at);
        if (at == s.len) break;
        try w.writeAll(s[from..at]);
        try std.json.Stringify.encodeJsonStringChars(s[at..][0..1], .{}, w);
        at += 1;
        from = at;
    }
    try w.writeAll(s[from..]);
    try w.writeByte('"');
}

/// The index of the first byte at or after `from` that a JSON string has to
/// escape — a control character, a quote or a backslash — or `s.len`.
fn clean(s: []const u8, from: usize) usize {
    const lanes = 16;
    const Chunk = @Vector(lanes, u8);
    var at = from;
    while (at + lanes <= s.len) : (at += lanes) {
        const chunk: Chunk = s[at..][0..lanes].*;
        const control = chunk < @as(Chunk, @splat(0x20));
        const quote = chunk == @as(Chunk, @splat('"'));
        const backslash = chunk == @as(Chunk, @splat('\\'));
        if (@reduce(.Or, control) or @reduce(.Or, quote) or @reduce(.Or, backslash)) break;
    }
    while (at < s.len and !escaped(s[at])) at += 1;
    return at;
}

fn escaped(byte: u8) bool {
    return byte < 0x20 or byte == '"' or byte == '\\';
}
