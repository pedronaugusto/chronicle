//! The segmented line store a journal is built on: a directory of files, each
//! holding newline-terminated records, named by the sequence number of the
//! first record in it.
//!
//! ```
//! mylog/
//!   lock                          the writer's advisory lock
//!   00000000000000000001.log      records 1..800
//!   00000000000000000001.idx      byte offsets for those records
//!   00000000000000000801.log      records 801..  -- the active segment
//!   00000000000000000801.idx
//!   snapshot                      whatever the caller last wrote
//! ```
//!
//! Nothing here knows what a record means. It knows that a record is one line,
//! that a line carries a `seq` member, and that a segment's name is the `seq`
//! of its first record — which is what makes a cursor a seek instead of a
//! scan, and what lets the sequence survive a log `compact` empties.
//!
//! This file is internal. `chronicle.zig` is the package.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Log = @This();

/// Directories cannot be `fsync`ed on Windows, so the promise that a file has
/// been *named* durably is a POSIX-only one; see README.md.
const can_sync_dir = builtin.os.tag != .windows;

/// The file a writer holds its advisory lock on. It is never read or written:
/// locking a data file instead would mean the lock changed identity every time
/// a segment rotated.
pub const lock_name = "lock";
/// The snapshot `Journal.snapshot` writes. A file with the temporary name
/// beside it is stale and is never read.
pub const snapshot_name = "snapshot";

/// A named reader's cursor: `<name>` plus this. It is written beside the log
/// and is not part of it — nothing here reads one.
pub const cursor_extension = ".cursor";

/// A segment's name is the sequence number of its first record, zero-padded so
/// that the directory sorts in sequence order, plus one of these.
pub const segment_extension = ".log";
pub const index_extension = ".idx";
/// A segment `compact` is building. It is renamed into place once it is whole;
/// one left behind by a crash is stale and is never read.
pub const temporary_extension = ".tmp";

/// Digits in a segment's name. The largest sequence number a record can carry
/// is `maxInt(i64)`, nineteen digits, and twenty leaves the padding visibly
/// wider than anything that can appear in it.
pub const name_digits = 20;

/// What `open` does with a final line the previous writer did not finish.
pub const OnTruncated = enum {
    /// Report `error.TruncatedRecord` and leave the file exactly as found.
    fail,
    /// Drop the unterminated bytes and shorten the segment to the last
    /// complete record, so the next append is well formed.
    drop,
};

/// How often the bytes an append wrote are made durable.
///
/// It governs the record bytes only. The `fsync`s that make a rename atomic --
/// a snapshot, a compaction, a new segment's name -- are not optional under
/// any of these, because they are what the replacement promise is.
pub const Sync = enum {
    /// `fsync` before every `appendLine` returns, and once per `commit`.
    always,
    /// `fsync` when a segment is sealed and when the log is closed. Between
    /// those, an appended record has reached the operating system only.
    on_segment,
    /// Never from an append, a seal or a close. The bytes reach the operating
    /// system and it writes them back when it chooses.
    never,
};

/// Whether this process may write to the log.
pub const Access = enum {
    /// Take the exclusive advisory lock, repair a torn tail, maintain the
    /// indexes, append. A second `write` opener gets `error.Locked`.
    write,
    /// Take no lock and write nothing at all — not the log, not an index, not
    /// a repair — so it is safe beside the writer of the same log.
    read,
};

/// One segment, as the log knows it.
pub const Segment = struct {
    /// The sequence number of this segment's first record, and its name.
    base_seq: u64,
    /// The sequence number of its last record, or `base_seq - 1` when it holds
    /// none.
    last_seq: u64,
    /// Its length in bytes, records staged but not yet committed included.
    /// For the active segment it is what has reached the file after any
    /// `appendLine` or `commit`.
    bytes: u64,

    /// How many records it holds.
    pub fn count(segment: Segment) u64 {
        return segment.last_seq + 1 - segment.base_seq;
    }
};

/// How a log is opened. `Journal.Options` forwards these.
pub const Options = struct {
    access: Access = .write,
    on_truncated: OnTruncated = .drop,
    sync: Sync = .always,
    write_buffer_size: usize = 64 * 1024,
    read_buffer_size: usize = 64 * 1024,
    max_segment_bytes: u64 = 8 * 1024 * 1024,
    max_segment_records: ?u64 = null,
};

pub const ReadError = Allocator.Error || Io.Cancelable || Io.File.OpenError ||
    Io.File.StatError || Io.File.ReadPositionalError || Io.File.Reader.Error ||
    Io.File.Reader.SeekError || Io.Writer.Error ||
    error{ TruncatedRecord, CorruptRecord };

pub const OpenError = ReadError || Io.File.SetLengthError || Io.File.SyncError ||
    Io.File.WritePositionalError || Io.Dir.OpenError || Io.Dir.CreateDirPathError ||
    Io.Dir.DeleteFileError || error{ Locked, DiscontinuousSeq, ReadOnly };

pub const AppendError = Io.Cancelable || Io.Writer.Error || Io.File.OpenError ||
    Io.File.SyncError || Io.File.WritePositionalError || Allocator.Error ||
    error{ReadOnly};

pub const ScanError = ReadError;

pub const CompactError = OpenError || AppendError || Io.Dir.RenameError;

pub const TruncateError = CompactError || error{SeqTooOld};

pub const WriteFileError = Allocator.Error || Io.Cancelable || Io.File.OpenError ||
    Io.Writer.Error || Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError;

pub const SnapshotError = WriteFileError || error{ReadOnly};

gpa: Allocator,
/// The log's directory, as given to `open`. Owned.
path: []const u8,
/// An open handle on that directory, used for every file operation and for the
/// `fsync` that makes a rename durable.
dir: Io.Dir,
/// Held for the life of the log when `Options.access` is `.write`.
lock_file: ?Io.File,
options: Options,
/// Every segment, oldest first. The last one is the active segment: the only
/// one `appendLine` writes to. Empty only for a `.read` open of a directory
/// that has none yet.
segments: std.ArrayList(Segment),
/// The active segment, open for appending, and its index sidecar. Null under
/// `.read`, and while `compact` is rearranging the directory.
active: ?Active,
write_buf: []u8,
index_buf: []u8,
/// How many unterminated bytes `open` dropped from the end of the active
/// segment.
dropped_bytes: usize,

/// The two open files that make up the newest segment.
const Active = struct {
    file: Io.File,
    writer: Io.File.Writer,
    index_file: Io.File,
    index_writer: Io.File.Writer,
};

//========================================================================
// Names.
//========================================================================

/// The name of the file holding segment `base_seq`, with `extension`.
pub fn segmentName(
    base_seq: u64,
    comptime extension: []const u8,
) [name_digits + extension.len]u8 {
    var out: [name_digits + extension.len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>20}" ++ extension, .{base_seq}) catch unreachable;
    return out;
}

/// The sequence number a segment file's name encodes, or null when the name is
/// not one this package writes. Everything else in the directory is ignored.
fn parseSegmentName(name: []const u8) ?u64 {
    if (name.len != name_digits + segment_extension.len) return null;
    if (!std.mem.eql(u8, name[name_digits..], segment_extension)) return null;
    const seq = std.fmt.parseInt(u64, name[0..name_digits], 10) catch return null;
    if (seq == 0) return null;
    return seq;
}

//========================================================================
// Opening.
//========================================================================

/// Open the log directory at `path`, creating it when `Options.access` is
/// `.write`, take the lock, and work out what each segment covers.
///
/// This reads the whole of the active segment — to rebuild its index, to find
/// the last sequence number and to repair a torn tail — and one line of each
/// sealed segment. The cost is one segment plus one read per segment, never
/// the size of the log.
pub fn open(gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!Log {
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const write_buf = try gpa.alloc(u8, options.write_buffer_size);
    errdefer gpa.free(write_buf);
    const index_buf = try gpa.alloc(u8, 4096);
    errdefer gpa.free(index_buf);

    const dir = try openDir(io, path, options.access);
    errdefer dir.close(io);

    var lock_file: ?Io.File = null;
    if (options.access == .write) {
        lock_file = dir.createFile(io, lock_name, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.Locked,
            else => |e| return e,
        };
    }
    errdefer if (lock_file) |file| file.close(io);

    var log: Log = .{
        .gpa = gpa,
        .path = owned_path,
        .dir = dir,
        .lock_file = lock_file,
        .options = options,
        .segments = .empty,
        .active = null,
        .write_buf = write_buf,
        .index_buf = index_buf,
        .dropped_bytes = 0,
    };
    errdefer {
        log.closeActive(io);
        log.segments.deinit(gpa);
    }
    try log.load(io);
    return log;
}

fn openDir(io: Io, path: []const u8, access: Access) OpenError!Io.Dir {
    const cwd: Io.Dir = .cwd();
    return cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (access == .read) return error.FileNotFound;
            try cwd.createDirPath(io, path);
            return cwd.openDir(io, path, .{ .iterate = true });
        },
        else => |e| return e,
    };
}

/// `load`, as a caller may ask for it: read the directory again, keeping the
/// directory handle and the lock. A `.read` log picks up what the writer has
/// added since; a `.write` one picks up what its own `compact` rearranged.
pub fn reload(log: *Log, io: Io) OpenError!void {
    return log.load(io);
}

/// Close the active segment, forget every segment, and read the directory
/// again. The directory handle and the lock are kept, so this is also how
/// `compact` picks up the files it has just rearranged.
fn load(log: *Log, io: Io) OpenError!void {
    log.closeActive(io);
    log.segments.clearRetainingCapacity();
    try log.listSegments(io);

    if (log.segments.items.len == 0) {
        if (log.options.access == .read) return;
        try log.createSegment(io, 1);
    }

    // Every segment but the last was sealed by a rotation, which makes it
    // durable before it writes anything else: its length and its last record
    // are whatever they were then, and one read each says what it covers.
    for (log.segments.items[0 .. log.segments.items.len - 1]) |*segment| {
        segment.bytes = try log.fileLength(io, &segmentName(segment.base_seq, segment_extension));
        segment.last_seq = try log.sealedLastSeq(io, segment.*);
    }
    try log.resolveOverlaps(io);
    try log.openActive(io);
}

/// Collect the segment files in the directory, in sequence order.
fn listSegments(log: *Log, io: Io) OpenError!void {
    var iterator = log.dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const base_seq = parseSegmentName(entry.name) orelse continue;
        try log.segments.append(log.gpa, .{
            .base_seq = base_seq,
            .last_seq = base_seq - 1,
            .bytes = 0,
        });
    }
    std.mem.sort(Segment, log.segments.items, {}, struct {
        fn lessThan(_: void, a: Segment, b: Segment) bool {
            return a.base_seq < b.base_seq;
        }
    }.lessThan);
}

/// The sequence numbers must run without a gap or a repeat from the first
/// segment to the last, because a cursor that lands in a hole would be
/// ambiguous.
///
/// One overlap is legitimate. `compact` renames a rewritten segment into place
/// before it removes the one it replaced, so a crash between the two leaves
/// both: the replacement starts later and ends at the same record. That shape
/// is recognised and the replaced segment removed. Every other disagreement is
/// `error.DiscontinuousSeq`.
fn resolveOverlaps(log: *Log, io: Io) OpenError!void {
    var i: usize = 0;
    while (i + 1 < log.segments.items.len) {
        const earlier = log.segments.items[i];
        const later = log.segments.items[i + 1];
        if (earlier.last_seq + 1 == later.base_seq) {
            i += 1;
            continue;
        }
        if (earlier.last_seq < later.base_seq) return error.DiscontinuousSeq;
        if (try log.lastSeqOf(io, later) != earlier.last_seq) return error.DiscontinuousSeq;
        if (log.options.access == .write) {
            try log.deleteSegmentFiles(io, earlier.base_seq);
            try log.syncDir(io);
        }
        _ = log.segments.orderedRemove(i);
    }
}

/// The last sequence number a segment holds, whether or not it is sealed.
fn lastSeqOf(log: *Log, io: Io, segment: Segment) OpenError!u64 {
    var measured = segment;
    measured.bytes = try log.fileLength(io, &segmentName(segment.base_seq, segment_extension));
    return log.sealedLastSeq(io, measured);
}

/// The last sequence number of a sealed segment, from its index when the index
/// is good for it and from its last line when it is not.
fn sealedLastSeq(log: *Log, io: Io, segment: Segment) OpenError!u64 {
    if (segment.bytes == 0) return segment.base_seq - 1;
    if (try log.indexedCount(io, segment)) |count| return segment.base_seq + count - 1;
    const line = try log.lastLine(io, segment);
    defer log.gpa.free(line.bytes);
    if (!line.terminated) return error.TruncatedRecord;
    return seqOf(log.gpa, line.bytes) orelse error.CorruptRecord;
}

//========================================================================
// The index sidecar.
//
// A dense array of little-endian byte offsets, one per record, so that finding
// the record after a cursor is a read of eight bytes at
// `index_header_len + (seq - base_seq) * 8` and then one positional read in
// the segment. The header names the segment length the offsets were built
// from; it is zero while the segment is still being appended to, which is what
// makes a crashed writer's index read as stale rather than as wrong.
//========================================================================

const index_magic = "chridx\x01\n";
const index_header_len = 16;

fn indexHeader(segment_bytes: u64) [index_header_len]u8 {
    var header: [index_header_len]u8 = undefined;
    @memcpy(header[0..index_magic.len], index_magic);
    std.mem.writeInt(u64, header[8..16], segment_bytes, .little);
    return header;
}

/// How many records a usable index says a segment holds, or null when the
/// index is missing, stale, or does not describe this segment.
///
/// "Usable" is checked against the segment's length, which the header records,
/// and against the last sequence number, which the record at the last indexed
/// offset must carry and must end the segment with: an index that agrees with
/// both was built from exactly these bytes.
fn indexedCount(log: *Log, io: Io, segment: Segment) OpenError!?u64 {
    const file = log.dir.openFile(io, &segmentName(segment.base_seq, index_extension), .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);

    var header: [index_header_len]u8 = undefined;
    if ((file.readPositionalAll(io, &header, 0) catch return null) != header.len) return null;
    if (!std.mem.eql(u8, header[0..index_magic.len], index_magic)) return null;
    if (std.mem.readInt(u64, header[8..16], .little) != segment.bytes) return null;

    const length = try file.length(io);
    if (length < index_header_len) return null;
    const body = length - index_header_len;
    if (body == 0 or body % 8 != 0) return null;
    const count = body / 8;

    var slot: [8]u8 = undefined;
    if ((file.readPositionalAll(io, &slot, index_header_len + (count - 1) * 8) catch return null) != 8) return null;
    const offset = std.mem.readInt(u64, &slot, .little);
    if (offset >= segment.bytes) return null;

    const line = log.lineAt(io, segment, offset) catch return null;
    defer log.gpa.free(line.bytes);
    if (!line.terminated or offset + line.bytes.len + 1 != segment.bytes) return null;
    const seq = seqOf(log.gpa, line.bytes) orelse return null;
    if (seq != segment.base_seq + count - 1) return null;
    return count;
}

/// The byte offset of `seq` within its segment, from the index, or null when
/// no usable index says. A null answer is never wrong — it costs a scan.
fn indexedOffset(log: *Log, io: Io, segment: Segment, seq: u64) ?u64 {
    if (seq <= segment.base_seq or seq > segment.last_seq) return null;
    const slot = index_header_len + (seq - segment.base_seq) * 8;

    if (log.active) |*active| {
        if (segment.base_seq == log.segments.items[log.segments.items.len - 1].base_seq) {
            // The live index: what has been appended is in the buffer or in
            // the file, so a flush is all it takes to read it back.
            active.index_writer.interface.flush() catch return null;
            var bytes: [8]u8 = undefined;
            if ((active.index_file.readPositionalAll(io, &bytes, slot) catch return null) != 8) return null;
            return std.mem.readInt(u64, &bytes, .little);
        }
    }

    const count = (log.indexedCount(io, segment) catch return null) orelse blk: {
        log.rebuildIndex(io, segment) catch return null;
        break :blk (log.indexedCount(io, segment) catch return null) orelse return null;
    };
    if (segment.base_seq + count - 1 != segment.last_seq) return null;

    const file = log.dir.openFile(io, &segmentName(segment.base_seq, index_extension), .{}) catch return null;
    defer file.close(io);
    var bytes: [8]u8 = undefined;
    if ((file.readPositionalAll(io, &bytes, slot) catch return null) != 8) return null;
    return std.mem.readInt(u64, &bytes, .little);
}

/// Build `<base>.idx` for a sealed segment by scanning it once, which is what
/// a missing or stale index costs and what it costs only once. The header is
/// written last, so an interrupted rebuild leaves an index that reads as stale
/// and is simply rebuilt again.
fn rebuildIndex(log: *Log, io: Io, segment: Segment) OpenError!void {
    if (log.options.access == .read) return error.ReadOnly;
    const file = try log.dir.createFile(io, &segmentName(segment.base_seq, index_extension), .{ .truncate = true });
    defer file.close(io);
    var writer = file.writer(io, log.index_buf);
    try writer.interface.writeAll(&indexHeader(0));
    _ = try log.scanSegment(io, segment, &writer);
    try writer.interface.flush();
    try sealIndex(io, file, segment.bytes);
}

/// Stamp a finished index with the segment length it describes and make it
/// durable, which is what turns it from a cache being filled into one a later
/// process may take.
fn sealIndex(io: Io, file: Io.File, segment_bytes: u64) OpenError!void {
    try file.writePositionalAll(io, &indexHeader(segment_bytes), 0);
    try file.sync(io);
}

//========================================================================
// Reading.
//========================================================================

/// One line read back, and whether the newline that should end it was there.
const Line = struct {
    /// Owned by the caller.
    bytes: []u8,
    terminated: bool,
};

fn fileLength(log: *Log, io: Io, name: []const u8) OpenError!u64 {
    const file = try log.dir.openFile(io, name, .{});
    defer file.close(io);
    return file.length(io);
}

/// The line beginning at `offset`, read in bounded steps rather than by taking
/// the segment into memory.
fn lineAt(log: *Log, io: Io, segment: Segment, offset: u64) OpenError!Line {
    const file = try log.dir.openFile(io, &segmentName(segment.base_seq, segment_extension), .{});
    defer file.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(log.gpa);
    var chunk: [4096]u8 = undefined;
    var at = offset;
    while (at < segment.bytes) {
        const want: usize = @intCast(@min(chunk.len, segment.bytes - at));
        const read = try file.readPositionalAll(io, chunk[0..want], at);
        if (read == 0) break;
        if (std.mem.indexOfScalar(u8, chunk[0..read], '\n')) |newline| {
            try out.appendSlice(log.gpa, chunk[0..newline]);
            return .{ .bytes = try out.toOwnedSlice(log.gpa), .terminated = true };
        }
        try out.appendSlice(log.gpa, chunk[0..read]);
        at += read;
    }
    return .{ .bytes = try out.toOwnedSlice(log.gpa), .terminated = false };
}

/// The last line of a segment, found by reading backwards in doubling windows
/// so that the cost is the size of one record rather than of the segment.
fn lastLine(log: *Log, io: Io, segment: Segment) OpenError!Line {
    const file = try log.dir.openFile(io, &segmentName(segment.base_seq, segment_extension), .{});
    defer file.close(io);

    var window: u64 = 4096;
    while (true) {
        const from = segment.bytes -| window;
        const size: usize = @intCast(segment.bytes - from);
        const buffer = try log.gpa.alloc(u8, size);
        defer log.gpa.free(buffer);
        const read = try file.readPositionalAll(io, buffer, from);
        const bytes = buffer[0..read];
        const terminated = bytes.len != 0 and bytes[bytes.len - 1] == '\n';
        const body = if (terminated) bytes[0 .. bytes.len - 1] else bytes;
        if (std.mem.lastIndexOfScalar(u8, body, '\n')) |newline| {
            return .{ .bytes = try log.gpa.dupe(u8, body[newline + 1 ..]), .terminated = terminated };
        }
        if (from == 0) return .{ .bytes = try log.gpa.dupe(u8, body), .terminated = terminated };
        window *= 2;
    }
}

/// The `seq` member of a line, or null when the line is not an object carrying
/// one. It is the only thing the segment layer reads out of a record.
fn seqOf(gpa: Allocator, line: []const u8) ?u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return null;
    if (root != .object) return null;
    const seq = root.object.get("seq") orelse return null;
    if (seq != .integer or seq.integer < 1) return null;
    return @intCast(seq.integer);
}

const Scanned = struct {
    /// Complete, newline-terminated lines seen.
    lines: u64,
    /// Bytes up to and including the last newline.
    complete_bytes: u64,
};

/// Walk a segment's newlines, optionally writing each line's offset to an index
/// being built. Memory is one read buffer: no line is ever held.
fn scanSegment(log: *Log, io: Io, segment: Segment, index: ?*Io.File.Writer) OpenError!Scanned {
    var scanned: Scanned = .{ .lines = 0, .complete_bytes = 0 };
    if (segment.bytes == 0) return scanned;

    const file = try log.dir.openFile(io, &segmentName(segment.base_seq, segment_extension), .{});
    defer file.close(io);
    const buffer = try log.gpa.alloc(u8, log.options.read_buffer_size);
    defer log.gpa.free(buffer);

    var reader = file.reader(io, buffer);
    var offset: u64 = 0;
    while (offset < segment.bytes) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline| {
            reader.interface.toss(newline + 1);
            if (index) |writer| try writer.interface.writeInt(u64, offset, .little);
            scanned.lines += 1;
            offset += newline + 1;
            scanned.complete_bytes = offset;
        } else {
            reader.interface.toss(chunk.len);
            offset += chunk.len;
        }
    }
    return scanned;
}

/// A walk over the log's lines from some sequence number onward, holding one
/// read buffer and one line at a time however long the log is.
///
/// The segments it will visit are decided when it is made, so a `compact` or a
/// `dropSegmentsBefore` running beside it may leave it reading a file that has
/// been replaced; it answers with an error rather than with wrong records.
pub const Scan = struct {
    gpa: Allocator,
    dir: Io.Dir,
    /// The base sequence numbers of the segments still to walk, oldest first.
    bases: []u64,
    at: usize,
    file: ?Io.File,
    reader: Io.File.Reader,
    buffer: []u8,
    line: Io.Writer.Allocating,
    /// Where in the current segment the next line starts.
    position: u64,
    /// Whether an unterminated final line in the newest segment is the end of
    /// the walk rather than damage — true for a reader beside a live writer.
    tolerate_partial_tail: bool,

    pub fn deinit(scan: *Scan, io: Io) void {
        if (scan.file) |file| file.close(io);
        scan.line.deinit();
        scan.gpa.free(scan.buffer);
        scan.gpa.free(scan.bases);
        scan.* = undefined;
    }

    /// The next line, or null at the end of the log. The bytes are valid until
    /// the next call to `next` or to `deinit`.
    pub fn next(scan: *Scan, io: Io) ScanError!?[]const u8 {
        while (true) {
            if (scan.file == null) {
                if (scan.at >= scan.bases.len) return null;
                const file = try scan.dir.openFile(io, &segmentName(scan.bases[scan.at], segment_extension), .{});
                scan.file = file;
                scan.reader = file.reader(io, scan.buffer);
                if (scan.position != 0) try scan.reader.seekTo(scan.position);
            }
            scan.line.clearRetainingCapacity();
            const streamed = scan.reader.interface.streamDelimiterEnding(&scan.line.writer, '\n') catch |err| switch (err) {
                error.ReadFailed => return scan.reader.err.?,
                error.WriteFailed => return error.OutOfMemory,
            };
            const terminated = if (scan.reader.interface.takeByte()) |_| true else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return scan.reader.err.?,
            };
            if (terminated) {
                scan.position += streamed + 1;
                return scan.line.written();
            }
            if (streamed != 0) {
                const newest = scan.at + 1 == scan.bases.len;
                if (newest and scan.tolerate_partial_tail) return null;
                return error.TruncatedRecord;
            }
            scan.file.?.close(io);
            scan.file = null;
            scan.at += 1;
            scan.position = 0;
        }
    }
};

/// A `Scan` over `segments`, starting `position` bytes into the first of them.
fn scanOver(log: *Log, segments: []const Segment, position: u64) ScanError!Scan {
    const bases = try log.gpa.alloc(u64, segments.len);
    errdefer log.gpa.free(bases);
    for (segments, bases) |segment, *base| base.* = segment.base_seq;

    const buffer = try log.gpa.alloc(u8, log.options.read_buffer_size);
    errdefer log.gpa.free(buffer);

    return .{
        .gpa = log.gpa,
        .dir = log.dir,
        .bases = bases,
        .at = 0,
        .file = null,
        .reader = undefined,
        .buffer = buffer,
        .line = .init(log.gpa),
        .position = position,
        .tolerate_partial_tail = log.options.access == .read,
    };
}

/// A `Scan` positioned at the first record after `cursor`, as close to it as
/// the indexes allow.
///
/// The walk may begin a little before it — a caller with a cursor drops what it
/// has already seen — but never after it.
pub fn scanFrom(log: *Log, io: Io, cursor: u64) ScanError!Scan {
    if (log.segments.items.len == 0) return log.scanOver(&.{}, 0);

    var first: usize = 0;
    for (log.segments.items, 0..) |segment, i| {
        if (segment.base_seq <= cursor + 1) first = i;
    }
    if (log.segments.items[first].last_seq <= cursor and first + 1 < log.segments.items.len) {
        first += 1;
    }
    const position = log.indexedOffset(io, log.segments.items[first], cursor + 1) orelse 0;
    return log.scanOver(log.segments.items[first..], position);
}

//========================================================================
// Writing.
//========================================================================

/// The newest sequence number the log holds, or zero when it holds none.
pub fn lastSeq(log: *const Log) u64 {
    if (log.segments.items.len == 0) return 0;
    return log.segments.items[log.segments.items.len - 1].last_seq;
}

/// One below the oldest sequence number the log still holds.
pub fn baseSeq(log: *const Log) u64 {
    if (log.segments.items.len == 0) return 0;
    return log.segments.items[0].base_seq - 1;
}

/// Append one record's bytes and the newline that ends it, and make them
/// durable.
///
/// Returns only once the bytes are in the file and — unless `Options.sync`
/// says otherwise — on the disk. It is `stageLine` and `commit`, which is what
/// a batch does once around many records rather than once around each.
pub fn appendLine(log: *Log, io: Io, bytes: []const u8) AppendError!void {
    try log.stageLine(io, bytes);
    try log.commit(io);
}

/// Write one record's bytes and the newline that ends it into the active
/// segment's buffer, rotating first if this record would take the segment past
/// its limits.
///
/// Nothing written this way has reached the disk, or even the operating
/// system, until `commit` returns: a caller that stages must commit. The index
/// entry goes out unflushed and unsynced whichever way the record was written:
/// it is a cache, and a crash that loses it costs the next open a scan of one
/// segment.
pub fn stageLine(log: *Log, io: Io, bytes: []const u8) AppendError!void {
    if (log.active == null) return error.ReadOnly;
    var segment = &log.segments.items[log.segments.items.len - 1];

    const needed = bytes.len + 1;
    const over_bytes = segment.bytes + needed > log.options.max_segment_bytes;
    const over_records = if (log.options.max_segment_records) |limit| segment.count() >= limit else false;
    if (segment.count() > 0 and (over_bytes or over_records)) {
        // The rotation seals the segment being left, so the records staged
        // into it are durable before the new one is named.
        try log.rotate(io);
        segment = &log.segments.items[log.segments.items.len - 1];
    }

    const at = segment.bytes;
    const active = &log.active.?;
    try active.writer.interface.writeAll(bytes);
    try active.writer.interface.writeByte('\n');

    try active.index_writer.interface.writeInt(u64, at, .little);
    segment.bytes += needed;
    segment.last_seq += 1;
}

/// Put everything `stageLine` has written into the file, and — under
/// `Options.sync = .always` — on the disk.
///
/// One `fsync` however many records were staged, which is what makes a batch
/// cost one where a record at a time costs one each.
pub fn commit(log: *Log, io: Io) AppendError!void {
    if (log.active == null) return error.ReadOnly;
    const active = &log.active.?;
    try active.writer.interface.flush();
    if (log.options.sync == .always) try active.file.sync(io);
}

/// Seal the active segment and start a new one named after the record that
/// will go into it.
fn rotate(log: *Log, io: Io) AppendError!void {
    const segment = log.segments.items[log.segments.items.len - 1];
    {
        const active = &log.active.?;
        try active.writer.interface.flush();
        if (log.options.sync != .never) try active.file.sync(io);
        try active.index_writer.interface.flush();
        sealIndex(io, active.index_file, segment.bytes) catch {};
    }
    log.closeActive(io);

    const base_seq = segment.last_seq + 1;
    const file = try log.dir.createFile(io, &segmentName(base_seq, segment_extension), .{ .read = true, .truncate = false });
    errdefer file.close(io);
    try log.syncDir(io);
    const index_file = try log.dir.createFile(io, &segmentName(base_seq, index_extension), .{ .truncate = true });
    errdefer index_file.close(io);
    var index_writer = index_file.writer(io, log.index_buf);
    try index_writer.interface.writeAll(&indexHeader(0));

    try log.segments.append(log.gpa, .{ .base_seq = base_seq, .last_seq = base_seq - 1, .bytes = 0 });
    log.active = .{
        .file = file,
        .writer = file.writer(io, log.write_buf),
        .index_file = index_file,
        .index_writer = index_writer,
    };
}

/// Open the newest segment for appending, rebuild its index, and repair a final
/// line the previous writer did not finish.
fn openActive(log: *Log, io: Io) OpenError!void {
    const segment = &log.segments.items[log.segments.items.len - 1];
    const name = segmentName(segment.base_seq, segment_extension);

    if (log.options.access == .read) {
        segment.bytes = try log.fileLength(io, &name);
        const scanned = try log.scanSegment(io, segment.*, null);
        // A reader never shortens a file: bytes after the last newline are a
        // writer mid-append, not damage.
        segment.bytes = scanned.complete_bytes;
        segment.last_seq = segment.base_seq + scanned.lines - 1;
        return;
    }

    const file = try log.dir.createFile(io, &name, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    segment.bytes = try file.length(io);

    // The index has no durability of its own, so the active segment's is
    // rebuilt here, from the bytes that are actually in the file.
    const index_file = try log.dir.createFile(io, &segmentName(segment.base_seq, index_extension), .{ .truncate = true });
    errdefer index_file.close(io);
    var index_writer = index_file.writer(io, log.index_buf);
    try index_writer.interface.writeAll(&indexHeader(0));

    const scanned = try log.scanSegment(io, segment.*, &index_writer);
    if (scanned.complete_bytes != segment.bytes) switch (log.options.on_truncated) {
        .fail => return error.TruncatedRecord,
        .drop => {
            log.dropped_bytes = @intCast(segment.bytes - scanned.complete_bytes);
            try file.setLength(io, scanned.complete_bytes);
            segment.bytes = scanned.complete_bytes;
        },
    };
    try index_writer.interface.flush();
    segment.last_seq = segment.base_seq + scanned.lines - 1;

    var writer = file.writer(io, log.write_buf);
    writer.pos = segment.bytes;
    log.active = .{
        .file = file,
        .writer = writer,
        .index_file = index_file,
        .index_writer = index_writer,
    };
}

/// Create an empty segment file and make its name durable.
fn createSegment(log: *Log, io: Io, base_seq: u64) OpenError!void {
    if (log.options.access == .read) return error.ReadOnly;
    const file = try log.dir.createFile(io, &segmentName(base_seq, segment_extension), .{ .truncate = false });
    file.close(io);
    try log.syncDir(io);
    try log.segments.append(log.gpa, .{ .base_seq = base_seq, .last_seq = base_seq - 1, .bytes = 0 });
}

fn closeActive(log: *Log, io: Io) void {
    if (log.active) |*active| {
        active.writer.interface.flush() catch {};
        active.index_writer.interface.flush() catch {};
        active.file.close(io);
        active.index_file.close(io);
        log.active = null;
    }
}

/// `fsync` the log's directory, so that a file this process created or renamed
/// is still named after a power cut. Windows has no equivalent; there the call
/// is nothing, and README.md says so.
pub fn syncDir(log: *Log, io: Io) Io.File.SyncError!void {
    if (!can_sync_dir) return;
    const as_file: Io.File = .{ .handle = log.dir.handle, .flags = .{ .nonblocking = false } };
    as_file.sync(io) catch |err| switch (err) {
        // A filesystem that will not sync a directory handle is one where this
        // promise cannot be kept. It is not a reason to fail the write.
        error.AccessDenied, error.InputOutput => return,
        else => |e| return e,
    };
}

fn deleteSegmentFiles(log: *Log, io: Io, base_seq: u64) Io.Dir.DeleteFileError!void {
    try log.dir.deleteFile(io, &segmentName(base_seq, segment_extension));
    log.dir.deleteFile(io, &segmentName(base_seq, index_extension)) catch {};
}

//========================================================================
// Retention.
//========================================================================

/// Delete every sealed segment whose records are all at or before `seq`, and
/// report how many went.
///
/// This rewrites nothing and never touches the active segment, so it costs one
/// `unlink` per segment whatever the log holds. Nothing calls it for you:
/// dropping history is a decision, usually taken just after a `snapshot` that
/// covers it.
pub fn dropSegmentsBefore(log: *Log, io: Io, seq: u64) CompactError!u64 {
    if (log.options.access == .read) return error.ReadOnly;
    var dropped: u64 = 0;
    while (log.segments.items.len > 1 and log.segments.items[0].last_seq <= seq) {
        try log.deleteSegmentFiles(io, log.segments.items[0].base_seq);
        _ = log.segments.orderedRemove(0);
        dropped += 1;
    }
    if (dropped != 0) try log.syncDir(io);
    return dropped;
}

/// Drop every record after `seq`.
///
/// Segments entirely past the cut are unlinked newest first, so what is left
/// on the disk is always a continuous prefix; the segment holding `seq` is
/// then shortened to the byte at which the next record began, which is the
/// same in-place shortening `open` uses to repair a torn tail. A crash between
/// the two leaves a log that opens and still holds records this was asked to
/// drop, which is why calling it again is the answer.
///
/// `seq` may be one below the oldest record the log holds, which empties it
/// and leaves the segment named for the record that comes next -- the shape a
/// `compact` that keeps nothing leaves. Below that there is no record to
/// truncate to and the answer is `error.SeqTooOld`.
pub fn truncateAfter(log: *Log, io: Io, seq: u64) TruncateError!void {
    if (log.options.access == .read) return error.ReadOnly;
    if (log.segments.items.len == 0) return;
    if (seq >= log.lastSeq()) return;
    if (seq < log.baseSeq()) return error.SeqTooOld;

    // The segment the cut falls inside: the one holding `seq`, or the oldest
    // one when the cut is before every record it holds.
    var holder = log.segments.items[0];
    for (log.segments.items) |segment| {
        if (segment.base_seq <= seq and seq <= segment.last_seq) holder = segment;
    }
    const offset = try log.offsetAfter(io, holder, seq);

    log.closeActive(io);
    var i = log.segments.items.len;
    while (i > 0) {
        i -= 1;
        const segment = log.segments.items[i];
        if (segment.base_seq <= holder.base_seq) break;
        try log.deleteSegmentFiles(io, segment.base_seq);
    }
    try log.syncDir(io);

    if (offset != holder.bytes) {
        const file = try log.dir.createFile(io, &segmentName(holder.base_seq, segment_extension), .{ .truncate = false });
        defer file.close(io);
        try file.setLength(io, offset);
        if (log.options.sync != .never) try file.sync(io);
        // The index describes bytes that are no longer there. Removing it is
        // cheaper than leaving one the next open has to reject and rebuild.
        log.dir.deleteFile(io, &segmentName(holder.base_seq, index_extension)) catch {};
        try log.syncDir(io);
    }
    try log.load(io);
}

/// The byte offset inside `segment` at which the record after `seq` begins,
/// and `segment.bytes` when `seq` is the last record it holds.
fn offsetAfter(log: *Log, io: Io, segment: Segment, seq: u64) OpenError!u64 {
    var scan = try log.scanOver(&.{segment}, 0);
    defer scan.deinit(io);
    var offset: u64 = 0;
    var at = segment.base_seq;
    while (try scan.next(io)) |line| : (at += 1) {
        if (at > seq) break;
        offset += line.len + 1;
    }
    return offset;
}

/// Rewrite the log keeping only the records after `keep_after_seq`.
///
/// Whole segments are unlinked. The one segment the cut falls inside is
/// rewritten to a neighbouring file, which is `fsync`ed and renamed into place
/// under the name of its new first record, so what is on the disk is always a
/// whole log. A crash between that rename and the unlink leaves the replaced
/// segment behind, and the next `open` recognises it and removes it.
///
/// The sequence number survives a log emptied this way, because a segment's
/// name is the record that will go into it.
pub fn compact(log: *Log, io: Io, keep_after_seq: u64) CompactError!void {
    if (log.options.access == .read) return error.ReadOnly;
    if (log.segments.items.len == 0) return;
    const keep_from = @min(keep_after_seq, log.lastSeq()) + 1;
    if (keep_from <= log.segments.items[0].base_seq) return;

    var straddling: ?Segment = null;
    var aligned = false;
    for (log.segments.items) |segment| {
        if (segment.base_seq == keep_from) aligned = true;
        if (keep_from > segment.base_seq and keep_from <= segment.last_seq) straddling = segment;
    }

    if (straddling) |segment| {
        try log.rewriteSegment(io, segment, keep_from);
    } else if (!aligned) {
        // The cut is past the newest record: every segment goes, and an empty
        // one named for the record that comes next carries the sequence.
        log.closeActive(io);
        const file = try log.dir.createFile(io, &segmentName(keep_from, segment_extension), .{ .truncate = false });
        file.close(io);
        try log.syncDir(io);
    }

    for (log.segments.items) |segment| {
        if (segment.base_seq >= keep_from) continue;
        try log.deleteSegmentFiles(io, segment.base_seq);
    }
    try log.syncDir(io);
    try log.load(io);
}

/// Copy the records of `segment` from `keep_from` onward into a new segment
/// named for `keep_from`, durably, without holding the whole segment.
fn rewriteSegment(log: *Log, io: Io, segment: Segment, keep_from: u64) CompactError!void {
    const temporary = segmentName(keep_from, temporary_extension);
    errdefer log.dir.deleteFile(io, &temporary) catch {};

    {
        const out = try log.dir.createFile(io, &temporary, .{ .truncate = true });
        var closed = false;
        errdefer if (!closed) out.close(io);
        var writer = out.writer(io, log.write_buf);

        // From the start of the segment, so that the copy never depends on an
        // index: compaction is rare and one segment is bounded.
        var scan = try log.scanOver(&.{segment}, 0);
        defer scan.deinit(io);
        var seq = segment.base_seq;
        while (try scan.next(io)) |line| : (seq += 1) {
            if (seq < keep_from) continue;
            try writer.interface.writeAll(line);
            try writer.interface.writeByte('\n');
        }
        try writer.interface.flush();
        try out.sync(io);
        out.close(io);
        closed = true;
    }

    // Let go of the active segment before anything is renamed: Windows refuses
    // to replace a file this process still has open.
    log.closeActive(io);
    try log.dir.rename(&temporary, log.dir, &segmentName(keep_from, segment_extension), io);
    try log.syncDir(io);
}

//========================================================================
// Whole files beside the log.
//========================================================================

/// Write `bytes` to a neighbouring file, `fsync` it, rename it over `name` and
/// `fsync` the directory, so a reader sees either the whole old file or the
/// whole new one.
///
/// This checks nothing about `Options.access`: whether a file is part of the
/// log is the caller's to know. A snapshot is; a named reader's cursor is not,
/// which is what lets a `.read` log keep one.
pub fn writeAtomic(log: *Log, io: Io, name: []const u8, bytes: []const u8) WriteFileError!void {
    const temporary = try std.mem.concat(log.gpa, u8, &.{ name, temporary_extension });
    defer log.gpa.free(temporary);
    errdefer log.dir.deleteFile(io, temporary) catch {};
    {
        const file = try log.dir.createFile(io, temporary, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        try file.sync(io);
    }
    try log.dir.rename(temporary, log.dir, name, io);
    try log.syncDir(io);
}

/// `writeAtomic` over `<path>/snapshot`, which only a writer may replace.
pub fn writeSnapshot(log: *Log, io: Io, bytes: []const u8) SnapshotError!void {
    if (log.options.access == .read) return error.ReadOnly;
    return log.writeAtomic(io, snapshot_name, bytes);
}

//========================================================================
// Teardown.
//========================================================================

pub fn deinit(log: *Log, io: Io) void {
    if (log.active) |*active| {
        active.writer.interface.flush() catch {};
        if (log.options.sync != .never) active.file.sync(io) catch {};
        active.index_writer.interface.flush() catch {};
        // Leave the active index stamped with the length it describes, so that
        // the next open can take it rather than rebuild it.
        const segment = log.segments.items[log.segments.items.len - 1];
        if (segment.bytes != 0) sealIndex(io, active.index_file, segment.bytes) catch {};
        active.file.close(io);
        active.index_file.close(io);
        log.active = null;
    }
    if (log.lock_file) |file| file.close(io);
    log.segments.deinit(log.gpa);
    log.dir.close(io);
    log.gpa.free(log.write_buf);
    log.gpa.free(log.index_buf);
    log.gpa.free(log.path);
    log.* = undefined;
}
