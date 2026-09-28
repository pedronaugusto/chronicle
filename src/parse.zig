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
///
/// Except where `std.json` would panic instead of answering: a number with a
/// fraction or an exponent read into an integer it cannot cast (see
/// `guardSlice`) is `error.Overflow` here.
pub fn fromSlice(comptime T: type, arena: Allocator, bytes: []const u8, options: std.json.ParseOptions) Error!T {
    std.debug.assert(options.allocate == null);
    if (try fast(T, arena, bytes)) |v| return v;
    if (comptime risky(T, &.{})) try guardSlice(T, arena, bytes, options);
    return std.json.parseFromSliceLeaky(T, arena, bytes, options);
}

/// `std.json.parseFromValueLeaky(T, arena, value, options)`, with its answer,
/// except where it would panic (see `guardValue`): that is `error.Overflow`.
pub fn fromValue(comptime T: type, arena: Allocator, value: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
    if (comptime risky(T, &.{})) try guardValue(T, value, options);
    return std.json.parseFromValueLeaky(T, arena, value, options);
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

//=========================================================================
// Numbers std.json panics on.
//
// `std.json` in Zig 0.16.0 reads a number written with a fraction or an
// exponent into an integer through a float, and two of its checks let a
// value through that the cast after them cannot hold:
//
// - From bytes (`sliceToInt`), the value is an `f128` checked against
//   `maxInt(T)` converted to `f128`, then cast through `i128`. A value at or
//   past 2^127 panics in the cast whatever `T` is (`1.8e38` into a `u128`),
//   and so does one equal to `maxInt(T)` rounded up where `f128` cannot hold
//   `maxInt(T)` (2^127 into an `i128`).
// - From a `std.json.Value` (`innerParseFromValue`), a `.float` is an `f64`
//   checked the same way and cast straight to `T`, so the one value it lets
//   through is `maxInt(T)` rounded up: 2^64 into a `u64`, 2^63 into an `i64`.
//
// A record hand-edited into such a number would take the process down on
// replay rather than being reported as a record that cannot be read. So
// before `std.json` is given the bytes, or the value, the guards below walk
// them the way `std.json` would -- the same tokens to the same fields, the
// same options -- and answer `error.Overflow` where `std.json` would reach
// the panic. They stop at the first thing `std.json` would refuse, and let
// it refuse it: an input that does not reach a panic gets `std.json`'s own
// answer, value or error. A type with its own `jsonParse` or
// `jsonParseFromValue` is stepped over; what it reads is its own.
//=========================================================================

/// Whether `T` holds, anywhere, an integer `std.json` could fail to cast.
fn risky(comptime T: type, comptime within: []const type) bool {
    for (within) |outer| if (outer == T) return false;
    const inside = within ++ .{T};
    return switch (@typeInfo(T)) {
        .int => intRisky(T),
        .optional => |info| risky(info.child, inside),
        .@"union" => |info| for (info.fields) |field| {
            if (field.type != void and risky(field.type, inside)) break true;
        } else false,
        .@"struct" => |info| for (info.fields) |field| {
            if (!field.is_comptime and risky(field.type, inside)) break true;
        } else false,
        .pointer => |info| switch (info.size) {
            .one, .slice => risky(info.child, inside),
            else => false,
        },
        .array => |info| risky(info.child, inside),
        .vector => |info| risky(info.child, inside),
        else => false,
    };
}

/// Whether one of the casts can fail for `T`: its largest value is not exact
/// as an `f64` (so not as the bound either path checks against, rounded up),
/// or it is wider than `i128`.
fn intRisky(comptime T: type) bool {
    return @typeInfo(T).int.bits > 53;
}

/// The least integer too large for `T`, as a float: 2^bits, or 2^(bits-1)
/// signed. A power of two, so exact.
fn pastMax(comptime T: type, comptime F: type) F {
    const info = @typeInfo(T).int;
    const bits = if (info.signedness == .signed) info.bits - 1 else info.bits;
    return std.math.ldexp(@as(F, 1), bits);
}

/// Whether `std.json` reading `slice` -- a number, or a string it reads as
/// one -- into a `T` would reach a cast that cannot hold the value.
fn sliceBreaksCast(comptime T: type, slice: []const u8) bool {
    if (std.json.isNumberFormattedLikeAnInteger(slice)) return false;
    const float = std.fmt.parseFloat(f128, slice) catch return false;
    // `std.json`'s own checks, which answer an error before the cast.
    if (@round(float) != float) return false;
    if (float > @as(f128, @floatFromInt(std.math.maxInt(T)))) return false;
    if (float < @as(f128, @floatFromInt(std.math.minInt(T)))) return false;
    const i128_past = comptime std.math.ldexp(@as(f128, 1), 127);
    return float >= i128_past or float < -i128_past or float >= comptime pastMax(T, f128);
}

/// Whether `innerParseFromValue` given `float` for a `T` would reach a cast
/// that cannot hold it.
fn floatBreaksCast(comptime T: type, float: f64) bool {
    if (@round(float) != float) return false;
    if (float > @as(f64, @floatFromInt(std.math.maxInt(T)))) return false;
    if (float < @as(f64, @floatFromInt(std.math.minInt(T)))) return false;
    return float >= comptime pastMax(T, f64);
}

/// The walk ends: at `Overflow` because `std.json` would panic, at `Stop`
/// because it would answer first.
const WalkError = error{ Overflow, Stop, OutOfMemory };

/// `error.Overflow` when `std.json.parseFromSliceLeaky(T, ...)` would panic
/// on `bytes`; nothing otherwise.
fn guardSlice(comptime T: type, arena: Allocator, bytes: []const u8, options: std.json.ParseOptions) error{ Overflow, OutOfMemory }!void {
    var scanner: std.json.Scanner = .initCompleteInput(arena, bytes);
    defer scanner.deinit();
    var resolved = options;
    resolved.max_value_len = options.max_value_len orelse bytes.len;
    walkTokens(T, arena, &scanner, resolved) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.OutOfMemory => return error.OutOfMemory,
        error.Stop => {},
    };
}

/// One token, whole, or `Stop` where the scanner has none to give.
fn nextToken(arena: Allocator, scanner: *std.json.Scanner, options: std.json.ParseOptions) WalkError!std.json.Token {
    return scanner.nextAllocMax(arena, .alloc_if_needed, options.max_value_len.?) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Stop,
    };
}

fn peekToken(scanner: *std.json.Scanner) WalkError!std.json.TokenType {
    return scanner.peekNextTokenType() catch error.Stop;
}

fn expectToken(scanner: *std.json.Scanner, want: std.meta.Tag(std.json.Token)) WalkError!void {
    const token = scanner.next() catch return error.Stop;
    if (std.meta.activeTag(token) != want) return error.Stop;
}

fn skipToken(scanner: *std.json.Scanner) WalkError!void {
    scanner.skipValue() catch return error.Stop;
}

/// `std.json.innerParse`, reading nothing but what it would read into an
/// integer.
fn walkTokens(comptime T: type, arena: Allocator, scanner: *std.json.Scanner, options: std.json.ParseOptions) WalkError!void {
    switch (@typeInfo(T)) {
        .bool, .float => _ = try nextToken(arena, scanner, options),
        .int => {
            const token = try nextToken(arena, scanner, options);
            const slice = switch (token) {
                inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
                else => return error.Stop,
            };
            if (comptime intRisky(T)) {
                if (sliceBreaksCast(T, slice)) return error.Overflow;
            }
        },
        .optional => |info| {
            if (try peekToken(scanner) == .null) {
                try expectToken(scanner, .null);
            } else try walkTokens(info.child, arena, scanner, options);
        },
        .@"enum" => {
            if (comptime std.meta.hasFn(T, "jsonParse")) return skipToken(scanner);
            _ = try nextToken(arena, scanner, options);
        },
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "jsonParse")) return skipToken(scanner);
            try expectToken(scanner, .object_begin);
            const name = switch (try nextToken(arena, scanner, options)) {
                inline .string, .allocated_string => |slice| slice,
                else => return error.Stop,
            };
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    if (field.type == void) {
                        try expectToken(scanner, .object_begin);
                        try expectToken(scanner, .object_end);
                    } else try walkTokens(field.type, arena, scanner, options);
                    break;
                }
            } else return error.Stop;
            try expectToken(scanner, .object_end);
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                try expectToken(scanner, .array_begin);
                inline for (info.fields) |field| try walkTokens(field.type, arena, scanner, options);
                return expectToken(scanner, .array_end);
            }
            if (comptime std.meta.hasFn(T, "jsonParse")) return skipToken(scanner);
            try expectToken(scanner, .object_begin);
            var seen = [_]bool{false} ** info.fields.len;
            while (true) {
                const name = switch (try nextToken(arena, scanner, options)) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => return,
                    else => return error.Stop,
                };
                inline for (info.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, name)) {
                        if (seen[i] and options.duplicate_field_behavior == .@"error") return error.Stop;
                        try walkTokens(field.type, arena, scanner, options);
                        seen[i] = true;
                        break;
                    }
                } else {
                    if (!options.ignore_unknown_fields) return error.Stop;
                    try skipToken(scanner);
                }
            }
        },
        .array => |info| switch (try peekToken(scanner)) {
            .array_begin => {
                try expectToken(scanner, .array_begin);
                for (0..info.len) |_| try walkTokens(info.child, arena, scanner, options);
                try expectToken(scanner, .array_end);
            },
            .string => return if (info.child == u8) skipToken(scanner) else error.Stop,
            else => return error.Stop,
        },
        .vector => |info| {
            try expectToken(scanner, .array_begin);
            for (0..info.len) |_| try walkTokens(info.child, arena, scanner, options);
            try expectToken(scanner, .array_end);
        },
        .pointer => |info| switch (info.size) {
            .one => try walkTokens(info.child, arena, scanner, options),
            .slice => switch (try peekToken(scanner)) {
                .array_begin => {
                    try expectToken(scanner, .array_begin);
                    while (try peekToken(scanner) != .array_end) {
                        try walkTokens(info.child, arena, scanner, options);
                    }
                    try expectToken(scanner, .array_end);
                },
                .string => return if (info.child == u8) skipToken(scanner) else error.Stop,
                else => return error.Stop,
            },
            else => comptime unreachable,
        },
        else => comptime unreachable,
    }
}

/// `error.Overflow` when `std.json.parseFromValueLeaky(T, ...)` would panic
/// on `value`; nothing otherwise.
fn guardValue(comptime T: type, value: std.json.Value, options: std.json.ParseOptions) error{Overflow}!void {
    walkValue(T, value, options) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.Stop, error.OutOfMemory => {},
    };
}

/// `std.json.innerParseFromValue`, reading nothing but what it would read
/// into an integer.
fn walkValue(comptime T: type, value: std.json.Value, options: std.json.ParseOptions) WalkError!void {
    switch (@typeInfo(T)) {
        .bool, .float => {},
        .int => if (comptime intRisky(T)) switch (value) {
            .float => |float| if (floatBreaksCast(T, float)) return error.Overflow,
            .number_string, .string => |slice| if (sliceBreaksCast(T, slice)) return error.Overflow,
            else => {},
        },
        .optional => |info| if (value != .null) try walkValue(info.child, value, options),
        .@"enum" => {},
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return;
            if (value != .object or value.object.count() != 1) return error.Stop;
            var it = value.object.iterator();
            const entry = it.next().?;
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                    if (field.type != void) try walkValue(field.type, entry.value_ptr.*, options);
                    return;
                }
            }
            return error.Stop;
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                if (value != .array or value.array.items.len != info.fields.len) return error.Stop;
                inline for (info.fields, 0..) |field, i| try walkValue(field.type, value.array.items[i], options);
                return;
            }
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return;
            if (value != .object) return error.Stop;
            var it = value.object.iterator();
            while (it.next()) |entry| {
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                        try walkValue(field.type, entry.value_ptr.*, options);
                        break;
                    }
                } else if (!options.ignore_unknown_fields) return error.Stop;
            }
        },
        .array => |info| {
            if (value != .array) return error.Stop;
            if (value.array.items.len != info.len) return error.Stop;
            for (value.array.items) |item| try walkValue(info.child, item, options);
        },
        .vector => |info| {
            if (value != .array) return error.Stop;
            if (value.array.items.len != info.len) return error.Stop;
            for (value.array.items) |item| try walkValue(info.child, item, options);
        },
        .pointer => |info| switch (info.size) {
            .one => try walkValue(info.child, value, options),
            .slice => if (value == .array) {
                for (value.array.items) |item| try walkValue(info.child, item, options);
            },
            else => comptime unreachable,
        },
        else => comptime unreachable,
    }
}
