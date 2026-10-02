const smoke = @import("bench_options").smoke;
const builtin = @import("builtin");
const std = @import("std");

const record_bytes: usize = 200;
const Event = struct { value: u64, padding: []const u8 };

const Input = struct {
    bytes: []u8,
    count: usize,

    fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, count: usize) !Input {
        const needed = try std.math.mul(usize, count, record_bytes);
        const bytes = try gpa.alloc(u8, needed);
        errdefer gpa.free(bytes);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        if (try file.readPositionalAll(io, bytes, 0) != needed or count == 0) return error.InvalidInput;
        return .{ .bytes = bytes, .count = count };
    }

    fn line(input: Input, index: usize) []const u8 {
        return input.bytes[index * record_bytes .. (index + 1) * record_bytes];
    }

    fn deinit(input: *Input, gpa: std.mem.Allocator) void {
        gpa.free(input.bytes);
        input.* = undefined;
    }
};

fn seconds(started: std.Io.Timestamp, io: std.Io) f64 {
    const ns = started.durationTo(benchmarkNow(io)).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

fn printMetric(io: std.Io, side: []const u8, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ side, workload, metric, value, unit });
    try out.interface.flush();
}

fn fullSync(io: std.Io, file: std.Io.File) !void {
    if (builtin.os.tag == .macos) {
        switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
            .SUCCESS => return,
            .INVAL, .OPNOTSUPP => return file.sync(io),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            else => return file.sync(io),
        }
    }
    return file.sync(io);
}

fn prepare(io: std.Io, gpa: std.mem.Allocator, input_path: []const u8, path: []const u8, count: usize) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, input.bytes);
}

const SyncKind = enum { none, fsync, full };

fn appendWorkload(
    io: std.Io,
    gpa: std.mem.Allocator,
    input_path: []const u8,
    path: []const u8,
    count: usize,
    workload: []const u8,
    sync_kind: SyncKind,
) !void {
    var input = try Input.load(io, gpa, input_path, count);
    defer input.deinit(gpa);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    const started = benchmarkNow(io);
    if (std.mem.eql(u8, workload, "group_commit")) {
        for (0..count) |i| {
            try writer.interface.writeAll(input.line(i));
            if ((i + 1) % 100 == 0) {
                try writer.interface.flush();
                try fullSync(io, file);
            }
        }
    } else {
        for (0..count) |i| {
            try writer.interface.writeAll(input.line(i));
            try writer.interface.flush();
            switch (sync_kind) {
                .none => {},
                .fsync => try file.sync(io),
                .full => try fullSync(io, file),
            }
        }
    }
    try writer.interface.flush();
    const elapsed = seconds(started, io);
    const side = if (sync_kind == .fsync) "plain-zig-fsync" else "plain-zig";
    try printMetric(io, side, workload, "records_per_second", @as(f64, @floatFromInt(count)) / elapsed, "records/s");
    if (std.mem.eql(u8, workload, "append_no_fsync")) {
        const mb = @as(f64, @floatFromInt(input.bytes.len)) / 1_000_000.0;
        try printMetric(io, side, workload, "megabytes_per_second", mb / elapsed, "MB/s");
    }
}

fn replay(io: std.Io, gpa: std.mem.Allocator, path: []const u8, count: usize, from: usize, workload: []const u8, repetitions: usize) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        try reader.seekTo((from - 1) * record_bytes);
        var seen: usize = 0;
        var sum: u64 = 0;
        while (try reader.interface.takeDelimiter('\n')) |line| {
            _ = arena.reset(.retain_capacity);
            const event = try std.json.parseFromSliceLeaky(Event, arena.allocator(), line, .{});
            sum += event.value;
            seen += 1;
        }
        elapsed += seconds(started, io);
        const expected = count - from + 1;
        if (seen != expected or sum != expected) return error.FoldMismatch;
    }
    if (std.mem.eql(u8, workload, "replay_all")) {
        try printMetric(io, "plain-zig", workload, "records_per_second", @as(f64, @floatFromInt(count * repetitions)) / elapsed, "records/s");
    } else {
        try printMetric(io, "plain-zig", workload, "elapsed", elapsed * 1000.0 / @as(f64, @floatFromInt(repetitions)), "ms");
    }
}

fn reopen(io: std.Io, path: []const u8, repetitions: usize) !void {
    var elapsed: f64 = 0;
    for (0..repetitions) |_| {
        const started = benchmarkNow(io);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        const length = try file.length(io);
        elapsed += seconds(started, io);
        file.close(io);
        if (length == 0) return error.EmptyFile;
    }
    try printMetric(io, "plain-zig", "clean_reopen", "elapsed", elapsed * 1000.0 / @as(f64, @floatFromInt(repetitions)), "ms");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const workload = args.next() orelse return error.MissingWorkload;
    const input_path = args.next() orelse return error.MissingInput;
    const path = args.next() orelse return error.MissingPath;
    const count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCount, 10);

    if (std.mem.eql(u8, workload, "prepare")) return prepare(io, gpa, input_path, path, count);
    if (std.mem.eql(u8, workload, "append_no_fsync")) return appendWorkload(io, gpa, input_path, path, count, workload, .none);
    if (std.mem.eql(u8, workload, "append_fsync")) return appendWorkload(io, gpa, input_path, path, count, workload, .full);
    if (std.mem.eql(u8, workload, "append_fsync_weak")) return appendWorkload(io, gpa, input_path, path, count, "append_fsync", .fsync);
    if (std.mem.eql(u8, workload, "group_commit")) return appendWorkload(io, gpa, input_path, path, count, workload, .full);
    if (std.mem.eql(u8, workload, "replay_all")) return replay(io, gpa, path, count, 1, workload, 1);
    if (std.mem.eql(u8, workload, "replay_from_n")) {
        const from = try std.fmt.parseInt(usize, args.next() orelse return error.MissingFrom, 10);
        const repetitions = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 1;
        return replay(io, gpa, path, count, from, workload, repetitions);
    }
    if (std.mem.eql(u8, workload, "clean_reopen")) {
        const repetitions = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 1;
        return reopen(io, path, repetitions);
    }
    return error.UnknownWorkload;
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
