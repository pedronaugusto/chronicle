//! An event read back into what `std.json.parseFromSliceLeaky` returns for
//! it, in less time, when its bytes are in the shape `stringify` writes.
//!
//! Every record a replay hands on has its event parsed, and `std.json`'s
//! scanner walks a string one byte at a time through a state machine. The
//! bytes this package writes are one shape of JSON out of many: no
//! whitespace, members in the order they are declared, names spelled as
//! `std.json` spells them. That shape is read here directly — a string
//! scanned sixteen bytes at a time and handed back as a slice of the line,
//! as `std.json` hands it back, a member name compared as the constant it
//! is.
//!
//! Anything this reader does not expect sends the whole value to
//! `std.json`: whitespace, members out of order or missing or unknown, an
//! escape in a string, a number that is not a plain integer, a type it does
//! not read itself (a float, `std.json.Value`, a type with its own
//! `jsonParse`, a tuple). It stops at the first surprise and reports nothing
//! of its own, so an error, and every value in a line that is not in this
//! shape, is `std.json`'s. The suite holds the rest to `std.json` with a
//! differential property and a fuzz target.
//!
//! This file is internal. `chronicle.zig` is the package.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = std.json.ParseError(std.json.Scanner);

/// `std.json.parseFromSliceLeaky(T, arena, bytes, options)`, with its answer.
/// `options` must leave `allocate` at its default: a string is a slice of
/// `bytes` wherever `std.json` would make it one.
pub fn fromSlice(comptime T: type, arena: Allocator, bytes: []const u8, options: std.json.ParseOptions) Error!T {
    std.debug.assert(options.allocate == null);
    if (try fast(T, arena, bytes)) |v| return v;
    return std.json.parseFromSliceLeaky(T, arena, bytes, options);
}

/// The value, when `bytes` are in the written shape and `T` is a type this
/// reader reads; null to say "ask `std.json`".
pub fn fast(comptime T: type, arena: Allocator, bytes: []const u8) Allocator.Error!?T {
    if (comptime !readable(T, &.{})) return null;
    var cursor: Cursor = .{ .bytes = bytes, .at = 0 };
    const v = read(T, arena, &cursor) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusual => return null,
    };
    if (cursor.at != bytes.len) return null;
    return v;
}

/// Whether this reader reads a `T`, all the way down. A type that contains
/// itself is taken as readable where it recurs: whether it is readable is
/// what is being worked out, and the rest of it says.
fn readable(comptime T: type, comptime within: []const type) bool {
    for (within) |outer| if (outer == T) return true;
    const inside = within ++ .{T};
    return switch (@typeInfo(T)) {
        .bool => true,
        .int => |info| info.bits <= 128,
        .optional => |info| readable(info.child, inside),
        .@"enum" => |info| info.is_exhaustive and !std.meta.hasFn(T, "jsonParse"),
        .@"union" => |info| blk: {
            if (info.tag_type == null or std.meta.hasFn(T, "jsonParse")) break :blk false;
            for (info.fields) |field| {
                if (field.type != void and !readable(field.type, inside)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |info| blk: {
            if (info.is_tuple or std.meta.hasFn(T, "jsonParse")) break :blk false;
            for (info.fields) |field| {
                if (field.is_comptime or !readable(field.type, inside)) break :blk false;
            }
            break :blk true;
        },
        .pointer => |info| switch (info.size) {
            .one => @typeInfo(info.child) != .@"opaque" and readable(info.child, inside),
            .slice => info.sentinel() == null and
                (if (info.child == u8) info.is_const else readable(info.child, inside)),
            else => false,
        },
        // `std.json` reads a `[N]u8` from a string as well as from an array.
        .array => |info| info.sentinel() == null and info.child != u8 and readable(info.child, inside),
        else => false,
    };
}

const Cursor = struct {
    bytes: []const u8,
    at: usize,

    fn take(c: *Cursor, comptime expected: []const u8) error{Unusual}!void {
        if (!std.mem.startsWith(u8, c.bytes[c.at..], expected)) return error.Unusual;
        c.at += expected.len;
    }

    fn skip(c: *Cursor, comptime expected: []const u8) bool {
        if (!std.mem.startsWith(u8, c.bytes[c.at..], expected)) return false;
        c.at += expected.len;
        return true;
    }

    fn peek(c: *const Cursor) ?u8 {
        return if (c.at < c.bytes.len) c.bytes[c.at] else null;
    }
};

const ReadError = error{ OutOfMemory, Unusual };

fn read(comptime T: type, arena: Allocator, c: *Cursor) ReadError!T {
    switch (@typeInfo(T)) {
        .bool => {
            if (c.skip("true")) return true;
            if (c.skip("false")) return false;
            return error.Unusual;
        },
        .int => return integer(T, c),
        .optional => |info| {
            if (c.skip("null")) return null;
            return try read(info.child, arena, c);
        },
        .@"enum" => {
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (c.skip(comptime quoted(field.name))) return @field(T, field.name);
            }
            return error.Unusual;
        },
        .@"union" => |info| {
            try c.take("{");
            inline for (info.fields) |field| {
                if (c.skip(comptime quoted(field.name) ++ ":")) {
                    const v = if (field.type == void) blk: {
                        try c.take("{}");
                        break :blk @unionInit(T, field.name, {});
                    } else @unionInit(T, field.name, try read(field.type, arena, c));
                    try c.take("}");
                    return v;
                }
            }
            return error.Unusual;
        },
        .@"struct" => |info| {
            var v: T = undefined;
            try c.take("{");
            inline for (info.fields, 0..) |field, i| {
                try c.take(comptime (if (i == 0) "" else ",") ++ quoted(field.name) ++ ":");
                @field(v, field.name) = try read(field.type, arena, c);
            }
            try c.take("}");
            return v;
        },
        .pointer => |info| switch (info.size) {
            .one => {
                const v = try arena.create(info.child);
                v.* = try read(info.child, arena, c);
                return v;
            },
            .slice => {
                if (info.child == u8) return string(c);
                try c.take("[");
                var items: std.ArrayList(info.child) = .empty;
                if (c.skip("]")) return items.toOwnedSlice(arena);
                while (true) {
                    try items.append(arena, try read(info.child, arena, c));
                    if (c.skip("]")) return items.toOwnedSlice(arena);
                    try c.take(",");
                }
            },
            else => comptime unreachable,
        },
        .array => |info| {
            var v: T = undefined;
            try c.take("[");
            for (&v, 0..) |*item, i| {
                if (i != 0) try c.take(",");
                item.* = try read(info.child, arena, c);
            }
            try c.take("]");
            return v;
        },
        else => comptime unreachable,
    }
}

/// A plain JSON integer: an optional minus and then `0` or digits that do
/// not start with one. Anything else a JSON number may be — a fraction, an
/// exponent, `-0`, which `std.json` reads through a float — is unusual.
fn integer(comptime T: type, c: *Cursor) ReadError!T {
    const negative = c.skip("-");
    const from = c.at;
    while (c.at < c.bytes.len and std.ascii.isDigit(c.bytes[c.at])) c.at += 1;
    const digits = c.bytes[from..c.at];
    if (digits.len == 0) return error.Unusual;
    if (digits[0] == '0' and (digits.len > 1 or negative)) return error.Unusual;
    if (c.peek()) |next| switch (next) {
        '.', 'e', 'E' => return error.Unusual,
        else => {},
    };
    var magnitude: u128 = 0;
    for (digits) |digit| {
        const times = @mulWithOverflow(magnitude, 10);
        const plus = @addWithOverflow(times[0], digit - '0');
        if (times[1] != 0 or plus[1] != 0) return error.Unusual;
        magnitude = plus[0];
    }
    const signed: i129 = if (negative) -@as(i129, magnitude) else magnitude;
    return std.math.cast(T, signed) orelse error.Unusual;
}

/// A JSON string with no escape in it, as the slice of the input it is,
/// which is what `std.json` returns for one. An escape is unusual, and so
/// are the things `std.json` refuses: a raw control character, bytes that
/// are not UTF-8.
fn string(c: *Cursor) ReadError![]const u8 {
    try c.take("\"");
    const from = c.at;
    const lanes = 16;
    const Chunk = @Vector(lanes, u8);
    var at = from;
    const bytes = c.bytes;
    while (at + lanes <= bytes.len) : (at += lanes) {
        const chunk: Chunk = bytes[at..][0..lanes].*;
        const control = chunk < @as(Chunk, @splat(0x20));
        const quote = chunk == @as(Chunk, @splat('"'));
        const backslash = chunk == @as(Chunk, @splat('\\'));
        if (@reduce(.Or, control) or @reduce(.Or, quote) or @reduce(.Or, backslash)) break;
    }
    while (at < bytes.len and bytes[at] != '"') : (at += 1) {
        if (bytes[at] < 0x20 or bytes[at] == '\\') return error.Unusual;
    }
    if (at == bytes.len) return error.Unusual;
    const content = bytes[from..at];
    if (!std.unicode.utf8ValidateSlice(content)) return error.Unusual;
    c.at = at + 1;
    return content;
}

/// A name as `std.json` writes it, and so as this reader expects it.
fn quoted(comptime name: []const u8) []const u8 {
    comptime {
        var buffer: [2 + 6 * name.len]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        std.json.Stringify.encodeJsonString(name, .{}, &w) catch unreachable;
        const frozen = buffer[0..w.end].*;
        return &frozen;
    }
}
