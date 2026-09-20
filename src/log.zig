//! The segmented line store a journal is built on: a directory of files, each
//! holding newline-terminated records, named by the sequence number of the
//! first record in it.
//!
//! ```
//! mylog/
//!   lock                          the writer's advisory lock
//!   00000000000000000001.log      records 1..800
//!   00000000000000000001.idx      where some of those records start, and when
//!   00000000000000000801.log      records 801..  -- the active segment
//!   00000000000000000801.idx
//!   snapshot                      whatever the caller last wrote
//!   reports.cursor                where the named reader `reports` got to
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
const durable = @import("durable.zig");
const crc32c = @import("crc32c.zig");
const clone = @import("clone.zig");

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
const temporary_extension = ".tmp";

/// Digits in a segment's name. The largest sequence number a record can carry
/// is `maxInt(i64)`, nineteen digits, and twenty leaves the padding visibly
/// wider than anything that can appear in it.
pub const name_digits = 20;

/// The version of the record framing, written as the first line of every
/// segment file. A file whose first line is not one of these is refused by
/// name rather than read as if it were records.
const log_format: u32 = 1;

/// The first line of a segment: which format the records after it are in,
/// which sequence number the segment starts at, and what the first record's
/// back-link has to be.
const SegmentHeader = struct {
    version: u32,
    base_seq: u64,
    /// The checksum the first record in this file carries as its `p`. A fresh
    /// segment takes a random one, so a record from another file -- or from
    /// an earlier life of this one -- does not chain onto it; a rotation and
    /// a compaction carry the chain across, so the link is unbroken where the
    /// records are.
    root: u32,

    /// The line, without its newline. Long enough for twenty digits of `base`
    /// and ten of `root`.
    pub fn line(header: SegmentHeader, buffer: *[96]u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{{\"chronicle\":{d},\"base\":{d},\"root\":{d}}}",
            .{ header.version, header.base_seq, header.root },
        ) catch unreachable;
    }
};

/// The header a segment's first line carries, or null when that line is not
/// one. Nothing here guesses: a line that does not parse as this object is
/// not a segment header, and a segment whose first line is not one is not a
/// segment this package wrote.
fn parseSegmentHeader(gpa: Allocator, line: []const u8) ?SegmentHeader {
    if (!std.mem.startsWith(u8, line, "{\"chronicle\":")) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return null;
    if (root != .object) return null;
    const version = root.object.get("chronicle") orelse return null;
    const base = root.object.get("base") orelse return null;
    const chain = root.object.get("root") orelse return null;
    if (version != .integer or base != .integer or chain != .integer) return null;
    return .{
        .version = std.math.cast(u32, version.integer) orelse return null,
        .base_seq = std.math.cast(u64, base.integer) orelse return null,
        .root = std.math.cast(u32, chain.integer) orelse return null,
    };
}

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
/// It governs the record bytes only. The flushes that make a rename atomic --
/// a snapshot, a compaction, a new segment's name -- are not optional under
/// any of these, because they are what the replacement promise is.
///
/// What "durable" costs is a platform's answer and not this package's:
/// `durable.flush` names the call, and README.md has the row per platform.
pub const Sync = enum {
    /// Flush before every `appendLine` returns, and once per `commit`.
    always,
    /// Flush when a segment is sealed and when the log is closed. Between
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

/// The lowest and highest `at` of the records in one segment.
///
/// Nothing here assumes the timestamps rise with the sequence numbers: a log
/// stores the `at` it was handed, and a caller may hand it anything. So it is
/// the pair, not the ends, and a segment is skipped only when its *highest* is
/// below what is being looked for.
const Times = struct {
    lowest: i64,
    highest: i64,
    /// Whether no record's `at` was below the one before it. A segment where
    /// that holds can be searched by bisection; one where it does not has to
    /// be looked through.
    rising: bool,
    /// The last `at` seen, for `rising`.
    last: i64,

    /// What a segment with no records carries, and what one whose timestamps
    /// have not been read back carries: an empty range, which `known` reports
    /// as nothing to go on.
    pub const unknown: Times = .{
        .lowest = std.math.maxInt(i64),
        .highest = std.math.minInt(i64),
        .rising = true,
        .last = std.math.minInt(i64),
    };

    pub fn known(times: Times) bool {
        return times.lowest <= times.highest;
    }

    pub fn widen(times: *Times, at: i64) void {
        if (at < times.last) times.rising = false;
        times.last = at;
        times.lowest = @min(times.lowest, at);
        times.highest = @max(times.highest, at);
    }
};

/// One segment, as the log knows it.
const Segment = struct {
    /// The sequence number of this segment's first record, and its name.
    base_seq: u64,
    /// The sequence number of its last record, or `base_seq - 1` when it holds
    /// none.
    last_seq: u64,
    /// Its length in bytes, records staged but not yet committed included.
    /// For the active segment it is what has reached the file after any
    /// `appendLine` or `commit`.
    bytes: u64,
    /// What its records are stamped with, when that is known. It comes from
    /// the index header for a sealed segment and from the appends themselves
    /// for the active one; a sealed segment whose index has to be rebuilt
    /// carries `Times.unknown` until something asks.
    times: Times,
    /// What this segment's index has been proved to be. A sealed segment's
    /// bytes do not change, and nothing but this process writes its index, so
    /// the proof is taken once and held for as long as the log knows this
    /// segment -- which is until `load` reads the directory again.
    index: IndexState,
    /// How many bytes the file's first line takes, newline included: where
    /// the records start.
    header_bytes: u64,

    /// A segment as the directory first names it: a file whose length and
    /// contents nothing has read yet.
    pub fn named(base_seq: u64) Segment {
        return .{
            .base_seq = base_seq,
            .last_seq = base_seq - 1,
            .bytes = 0,
            .times = .unknown,
            .index = .unchecked,
            .header_bytes = 0,
        };
    }

    /// How many records it holds.
    pub fn count(segment: Segment) u64 {
        return segment.last_seq + 1 - segment.base_seq;
    }
};

/// Whether a segment's index has been checked against it, and what it said.
const IndexState = union(enum) {
    /// Nothing has asked yet.
    unchecked,
    /// There is no index describing these bytes, and this log has not been
    /// able to build one.
    none,
    /// It describes exactly these bytes.
    good: Indexed,
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
    preallocate_bytes: u64 = 0,
    index_interval_bytes: u64 = 4096,
    max_record_bytes: usize = 1024 * 1024,
};

pub const ReadError = Allocator.Error || Io.Cancelable || Io.File.OpenError ||
    Io.File.StatError || Io.File.ReadPositionalError || Io.File.Reader.Error ||
    Io.File.Reader.SeekError || Io.Writer.Error ||
    error{ TruncatedRecord, CorruptRecord, UnsupportedFormat, RecordTooLarge };

pub const OpenError = ReadError || Io.File.SetLengthError || Io.File.SyncError ||
    Io.File.WritePositionalError || Io.Dir.OpenError || Io.Dir.CreateDirPathError ||
    Io.Dir.DeleteFileError || error{ Locked, DiscontinuousSeq, ReadOnly };

pub const AppendError = Io.Cancelable || Io.Writer.Error || Io.File.OpenError ||
    Io.File.SyncError || Io.File.WritePositionalError || Io.File.SetLengthError ||
    Allocator.Error || error{ReadOnly};

pub const ScanError = ReadError;

pub const CompactError = OpenError || AppendError || Io.Dir.RenameError;

pub const TruncateError = CompactError || error{SeqTooOld};

pub const WriteFileError = Allocator.Error || Io.Cancelable || Io.File.OpenError ||
    Io.Writer.Error || Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError;

pub const SnapshotError = WriteFileError || error{ReadOnly};

pub const SealError = Io.File.WritePositionalError || Io.File.SyncError;

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
/// The checksum of the newest record, which the next one carries as its `p`.
/// For an empty segment it is the segment header's `root`.
chain: u32,
/// How many files have been opened to consult a sealed segment's index, and
/// how many entries have been read out of one. Neither is part of any
/// promise: they are what the suite counts to prove that a seek costs the
/// index once per segment rather than once per seek, and that a lookup by
/// time halves the entries rather than reading them.
index_opens: u64,
index_reads: u64,
/// One open handle on a sealed segment's index, kept between seeks. A fold
/// that seeks repeatedly stays in one segment for as long as it is reading
/// it, so one handle is the whole of the win and a cache is not needed.
held_index: ?HeldIndex,

/// The two open files that make up the newest segment.
const Active = struct {
    file: Io.File,
    writer: Io.File.Writer,
    index_file: Io.File,
    index_writer: Io.File.Writer,
    /// How far the segment file has been zero-filled ahead of the records in
    /// it. Equal to the committed length when `Options.preallocate_bytes` is
    /// zero, which is to say when nothing is reserved.
    preallocated: u64,
    /// The index being filled beside the records.
    builder: Builder,
};

//========================================================================
// Names.
//========================================================================

/// The name of the file holding segment `base_seq`, with `extension`.
pub fn segmentName(
    base_seq: u64,
    comptime extension: []const u8,
) [name_digits + extension.len:0]u8 {
    // Zero-terminated: some of the calls a copy makes go to the operating
    // system by name rather than through an open file.
    var out: [name_digits + extension.len:0]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>20}" ++ extension, .{base_seq}) catch unreachable;
    out[out.len] = 0;
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
        .chain = 0,
        .index_opens = 0,
        .index_reads = 0,
        .held_index = null,
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
    log.releaseIndex(io);
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
        try log.describeSealed(io, segment);
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
        try log.segments.append(log.gpa, .named(base_seq));
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
    try log.describeSealed(io, &measured);
    return measured.last_seq;
}

/// Fill in what a sealed segment holds: its last sequence number, from its
/// index when the index is good for it and from its last line when it is not,
/// and the timestamps its index header carries.
fn describeSealed(log: *Log, io: Io, segment: *Segment) OpenError!void {
    segment.times = .unknown;
    if (segment.bytes == 0) {
        segment.last_seq = segment.base_seq - 1;
        return;
    }
    const head = try log.readSegmentHeader(io, segment.*);
    segment.header_bytes = head.header_bytes;
    if (try log.readIndex(io, segment.*)) |indexed| {
        segment.last_seq = segment.base_seq + indexed.count - 1;
        segment.times = indexed.times;
        segment.index = .{ .good = indexed };
        return;
    }
    if (segment.bytes == head.header_bytes) {
        // The line that says what the file is, and no records after it: a
        // segment a compaction emptied, carrying the sequence number.
        segment.last_seq = segment.base_seq - 1;
        return;
    }
    const line = try log.lastLine(io, segment.*);
    defer log.gpa.free(line.bytes);
    if (!line.terminated) return error.TruncatedRecord;
    segment.last_seq = seqOf(log.gpa, line.bytes) orelse return error.CorruptRecord;
}

//========================================================================
// The index sidecar.
//
// A header and then entries, each naming a record: its sequence number, its
// byte offset in the segment, and the `at` it was written with. Finding the
// record after a cursor is a bisection of the entries and then a walk of at
// most `Options.index_interval_bytes` of the segment; finding the first
// record at or after a moment is a bisection of the timestamps beside them,
// with no segment file opened at all when they do not fall.
//
// An entry per record is not the default, because a segment of 95-byte
// records would spend a sixth of its size on one. One entry per 4096 bytes
// of segment costs a fortieth of that and bounds the walk after the
// bisection at one entry's worth of records.
//
// The header names the segment length the offsets were built from -- zero
// while the segment is still being appended to, which is what makes a
// crashed writer's index read as stale rather than as wrong -- the segment
// it belongs to, how many records that is, the lowest and highest `at` in
// it, whether those `at`s rise, and a checksum of the entries. An index that
// agrees with all of that was built from exactly these bytes.
//
// The magic carries the format version. An index written by an older version
// reads as stale, so an old journal opens unchanged and its indexes are built
// again the first time something asks for one.
//========================================================================

const index_magic = "chridx\x03\n";
const index_header_len = 96;
const index_entry_len = 24;

/// Bit 0 of the header's flags: no record's `at` is below the one before it,
/// so the timestamps can be bisected.
const index_rising: u32 = 1;

/// What a header says, and what `sealIndex` writes.
const IndexHeader = struct {
    /// The segment length these offsets were built from, zero while it is
    /// still being appended to.
    segment_bytes: u64,
    base_seq: u64,
    /// Records in the segment, not entries in the index.
    records: u64,
    times: Times,
    interval: u32,
    /// CRC32C of every entry byte, which is what proves the entries are the
    /// ones that were written.
    entries_checksum: u32,

    fn bytes(header: IndexHeader) [index_header_len]u8 {
        var out: [index_header_len]u8 = @splat(0);
        @memcpy(out[0..index_magic.len], index_magic);
        std.mem.writeInt(u64, out[8..16], header.segment_bytes, .little);
        std.mem.writeInt(i64, out[16..24], header.times.lowest, .little);
        std.mem.writeInt(i64, out[24..32], header.times.highest, .little);
        std.mem.writeInt(u64, out[32..40], header.base_seq, .little);
        std.mem.writeInt(u64, out[40..48], header.records, .little);
        std.mem.writeInt(u32, out[48..52], header.interval, .little);
        std.mem.writeInt(u32, out[52..56], if (header.times.rising) index_rising else 0, .little);
        // 56..92 is spare, and is zero. It is there so that the next fact an
        // index has to carry is a field and not a new format.
        std.mem.writeInt(u32, out[92..96], header.entries_checksum, .little);
        return out;
    }

    fn parse(raw: *const [index_header_len]u8) ?IndexHeader {
        if (!std.mem.eql(u8, raw[0..index_magic.len], index_magic)) return null;
        const flags = std.mem.readInt(u32, raw[52..56], .little);
        const highest = std.mem.readInt(i64, raw[24..32], .little);
        return .{
            .segment_bytes = std.mem.readInt(u64, raw[8..16], .little),
            .base_seq = std.mem.readInt(u64, raw[32..40], .little),
            .records = std.mem.readInt(u64, raw[40..48], .little),
            .times = .{
                .lowest = std.mem.readInt(i64, raw[16..24], .little),
                .highest = highest,
                .rising = flags & index_rising != 0,
                .last = highest,
            },
            .interval = std.mem.readInt(u32, raw[48..52], .little),
            .entries_checksum = std.mem.readInt(u32, raw[92..96], .little),
        };
    }
};

/// One entry: which record, where it is, and when it was.
const IndexEntry = struct {
    seq: u64,
    offset: u64,
    at: i64,

    fn bytes(entry: IndexEntry) [index_entry_len]u8 {
        var out: [index_entry_len]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], entry.seq, .little);
        std.mem.writeInt(u64, out[8..16], entry.offset, .little);
        std.mem.writeInt(i64, out[16..24], entry.at, .little);
        return out;
    }

    fn parse(raw: *const [index_entry_len]u8) IndexEntry {
        return .{
            .seq = std.mem.readInt(u64, raw[0..8], .little),
            .offset = std.mem.readInt(u64, raw[8..16], .little),
            .at = std.mem.readInt(i64, raw[16..24], .little),
        };
    }
};

/// An index being written: the active segment's, or one being rebuilt.
///
/// It decides which records get an entry, keeps the running checksum of the
/// ones it has written, and carries everything `sealIndex` needs at the end.
const Builder = struct {
    base_seq: u64,
    interval: u64,
    entries: u64,
    checksum: u32,
    last_offset: u64,

    fn init(base_seq: u64, interval: u64) Builder {
        return .{
            .base_seq = base_seq,
            .interval = interval,
            .entries = 0,
            .checksum = crc32c.initial,
            .last_offset = 0,
        };
    }

    /// Whether this record earns an entry. The first one in a segment always
    /// does, so a bisection always has somewhere to start.
    fn wants(builder: Builder, offset: u64) bool {
        if (builder.entries == 0) return true;
        if (builder.interval == 0) return true;
        return offset - builder.last_offset >= builder.interval;
    }

    /// Offer the record whose position in the segment is `ordinal`.
    fn record(
        builder: *Builder,
        writer: *Io.File.Writer,
        ordinal: u64,
        offset: u64,
        at: i64,
    ) Io.Writer.Error!void {
        if (!builder.wants(offset)) return;
        const entry: IndexEntry = .{ .seq = builder.base_seq + ordinal, .offset = offset, .at = at };
        const raw = entry.bytes();
        try writer.interface.writeAll(&raw);
        builder.checksum = crc32c.update(builder.checksum, &raw);
        builder.entries += 1;
        builder.last_offset = offset;
    }
};

/// A `Builder` and the writer it writes through, which is what a scan of a
/// segment is handed when it is building an index on the way.
const IndexSink = struct {
    builder: *Builder,
    writer: *Io.File.Writer,

    fn record(sink: *IndexSink, ordinal: u64, offset: u64, at: i64) Io.Writer.Error!void {
        return sink.builder.record(sink.writer, ordinal, offset, at);
    }
};

/// What a usable index says about its segment.
const Indexed = struct {
    /// How many records the segment holds.
    count: u64,
    /// How many entries the index holds, which is fewer unless there is one
    /// per record.
    entries: u64,
    /// Bytes of segment between entries, zero for one per record.
    interval: u64,
    /// The timestamps in it, or `Times.unknown` when the segment held a record
    /// whose `at` could not be read and there is therefore nothing to skip by.
    times: Times,
};

/// What a usable index says a segment holds, or null when the index is
/// missing, stale, written by an older version, or does not describe this
/// segment.
///
/// "Usable" is three facts agreeing: the header names this segment and the
/// length it currently has, and the checksum in the header is the checksum of
/// the entries that follow it. An index that agrees with all three was built
/// from exactly these bytes and nothing has changed since.
fn readIndex(log: *Log, io: Io, segment: Segment) OpenError!?Indexed {
    const file = log.holdIndex(io, segment.base_seq) orelse return null;

    var raw: [index_header_len]u8 = undefined;
    if ((file.readPositionalAll(io, &raw, 0) catch return null) != raw.len) return null;
    const header = IndexHeader.parse(&raw) orelse return null;
    if (header.segment_bytes != segment.bytes) return null;
    if (header.base_seq != segment.base_seq) return null;

    const length = file.length(io) catch return null;
    if (length < index_header_len) return null;
    const body = length - index_header_len;
    if (body % index_entry_len != 0) return null;
    const entries = body / index_entry_len;
    if (entries == 0 and header.records != 0) return null;
    if (entries > header.records) return null;

    var checksum = crc32c.initial;
    var buffer: [64 * index_entry_len]u8 = undefined;
    var at: u64 = index_header_len;
    while (at < length) {
        const want: usize = @intCast(@min(buffer.len, length - at));
        const read = file.readPositionalAll(io, buffer[0..want], at) catch return null;
        if (read != want) return null;
        checksum = crc32c.update(checksum, buffer[0..want]);
        at += want;
    }
    if (~checksum != header.entries_checksum) return null;

    return .{
        .count = header.records,
        .entries = entries,
        .interval = header.interval,
        .times = header.times,
    };
}

/// The entry at `slot` of a segment's index, read through an open handle.
fn indexEntryAt(log: *Log, io: Io, file: Io.File, slot: u64) ?IndexEntry {
    log.index_reads += 1;
    var raw: [index_entry_len]u8 = undefined;
    const offset = index_header_len + slot * index_entry_len;
    if ((file.readPositionalAll(io, &raw, offset) catch return null) != raw.len) return null;
    return IndexEntry.parse(&raw);
}

/// The slot of the last entry whose sequence number is at or below `seq`, or
/// null when the first entry is already past it.
fn bisectSeq(log: *Log, io: Io, file: Io.File, entries: u64, seq: u64) ?u64 {
    var low: u64 = 0;
    var high: u64 = entries;
    var found: ?u64 = null;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = log.indexEntryAt(io, file, middle) orelse return null;
        if (entry.seq <= seq) {
            found = middle;
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return found;
}

/// One sealed segment's index, open.
const HeldIndex = struct {
    base_seq: u64,
    file: Io.File,
};

/// Let go of the index handle being held, if there is one.
fn releaseIndex(log: *Log, io: Io) void {
    if (log.held_index) |held| held.file.close(io);
    log.held_index = null;
}

/// The open index of a sealed segment, opening it if the one being held is
/// another segment's.
fn holdIndex(log: *Log, io: Io, base_seq: u64) ?Io.File {
    if (log.held_index) |held| {
        if (held.base_seq == base_seq) return held.file;
        held.file.close(io);
        log.held_index = null;
    }
    log.index_opens += 1;
    const file = log.dir.openFile(io, &segmentName(base_seq, index_extension), .{}) catch return null;
    log.held_index = .{ .base_seq = base_seq, .file = file };
    return file;
}

/// What a sealed segment's index says, proved against the segment once.
///
/// The proof is what used to happen on every lookup. None of it can change
/// while this log holds the write lock and the segment is sealed, so it is
/// taken once and the answer kept on the segment.
///
/// `may_write` is false for a walk that does not hold the journal's lock: it
/// reads an index that is already there and never builds one.
fn provenIndex(log: *Log, io: Io, at: usize, may_write: bool) ?Indexed {
    const segment = &log.segments.items[at];
    switch (segment.index) {
        .good => |indexed| return indexed,
        .none => return null,
        .unchecked => {},
    }
    if (log.readIndex(io, segment.*) catch null) |indexed| {
        segment.index = .{ .good = indexed };
        return indexed;
    }
    if (!may_write or log.options.access == .read) {
        // Left unchecked rather than refused: a walk that may not write has
        // not proved there is no index, only that it will not make one.
        if (!may_write) return null;
        segment.index = .none;
        return null;
    }
    log.rebuildIndex(io, segment.*) catch {
        segment.index = .none;
        return null;
    };
    if (log.readIndex(io, segment.*) catch null) |indexed| {
        segment.index = .{ .good = indexed };
        return indexed;
    }
    segment.index = .none;
    return null;
}

/// The byte offset to start reading `seq` from, inside the segment at `at`,
/// or null when no usable index says.
///
/// It may be the offset of an earlier record: with one entry per
/// `index_interval_bytes` the answer is the entry before the record, and the
/// walk steps over what is between them. A null answer is never wrong — it
/// costs a walk from the segment's first record.
fn indexedOffset(log: *Log, io: Io, at: usize, seq: u64, may_write: bool) ?u64 {
    const segment = log.segments.items[at];
    if (seq <= segment.base_seq or seq > segment.last_seq) return null;

    if (log.active) |*active| {
        if (at + 1 == log.segments.items.len) {
            // The live index: what has been appended is in the buffer or in
            // the file, so a flush is all it takes to read it back.
            active.index_writer.interface.flush() catch return null;
            const slot = log.bisectSeq(io, active.index_file, active.builder.entries, seq) orelse return null;
            const entry = log.indexEntryAt(io, active.index_file, slot) orelse return null;
            return entry.offset;
        }
    }

    const indexed = log.provenIndex(io, at, may_write) orelse return null;
    if (segment.base_seq + indexed.count - 1 != segment.last_seq) return null;

    const file = log.holdIndex(io, segment.base_seq) orelse return null;
    const slot = log.bisectSeq(io, file, indexed.entries, seq) orelse return null;
    const entry = log.indexEntryAt(io, file, slot) orelse return null;
    return entry.offset;
}

/// Build `<base>.idx` for a sealed segment by scanning it once, which is what
/// a missing or stale index costs and what it costs only once. The header is
/// written last, so an interrupted rebuild leaves an index that reads as stale
/// and is simply rebuilt again.
fn rebuildIndex(log: *Log, io: Io, segment: Segment) OpenError!void {
    if (log.options.access == .read) return error.ReadOnly;
    log.releaseIndex(io);
    const file = try log.dir.createFile(io, &segmentName(segment.base_seq, index_extension), .{ .truncate = true });
    defer file.close(io);
    var writer = file.writer(io, log.index_buf);
    var builder: Builder = .init(segment.base_seq, log.options.index_interval_bytes);
    try writer.interface.writeAll(&placeholderHeader(segment.base_seq, log.options.index_interval_bytes));
    var sink: IndexSink = .{ .builder = &builder, .writer = &writer };
    const scanned = try log.scanSegment(io, segment, &sink);
    try writer.interface.flush();
    try sealIndex(io, file, .{
        .segment_bytes = segment.bytes,
        .base_seq = segment.base_seq,
        .records = scanned.lines,
        .times = scanned.times,
        .interval = @intCast(builder.interval),
        .entries_checksum = ~builder.checksum,
    });
    log.releaseIndex(io);
}

/// The header an index carries while it is being filled: no segment length,
/// so it reads as stale until it is sealed.
fn placeholderHeader(base_seq: u64, interval: u64) [index_header_len]u8 {
    const header: IndexHeader = .{
        .segment_bytes = 0,
        .base_seq = base_seq,
        .records = 0,
        .times = .unknown,
        .interval = @intCast(interval),
        .entries_checksum = 0,
    };
    return header.bytes();
}

/// Stamp a finished index with everything that proves it and make it durable,
/// which is what turns it from a cache being filled into one a later process
/// may take.
fn sealIndex(io: Io, file: Io.File, header: IndexHeader) SealError!void {
    try file.writePositionalAll(io, &header.bytes(), 0);
    try durable.sync(io, file, .whole);
}

/// The active segment's index, reopened for appending, when the one on the
/// disk was sealed against exactly the bytes the segment now holds.
const Resumed = struct {
    file: Io.File,
    writer: Io.File.Writer,
    indexed: Indexed,
    builder: Builder,
};

/// Take the index a clean close left, when it describes this segment at this
/// length, so that opening a log costs no scan at all.
///
/// The header is stamped back to "still being appended to" before anything
/// else happens, so a crash from here on leaves an index that reads as stale
/// and is rebuilt, exactly as one a crash left half-written does.
fn resumeIndex(log: *Log, io: Io, segment: Segment) OpenError!?Resumed {
    if (segment.bytes == 0) return null;
    const indexed = (try log.readIndex(io, segment)) orelse return null;
    if (indexed.interval != log.options.index_interval_bytes) return null;

    // The running checksum has to carry on from the entries already there,
    // and the bisection has to know where the last one sits.
    const held = log.holdIndex(io, segment.base_seq) orelse return null;
    var builder: Builder = .init(segment.base_seq, indexed.interval);
    builder.entries = indexed.entries;
    if (indexed.entries != 0) {
        const last = log.indexEntryAt(io, held, indexed.entries - 1) orelse return null;
        builder.last_offset = last.offset;
    }
    const length = index_header_len + indexed.entries * index_entry_len;
    {
        var buffer: [64 * index_entry_len]u8 = undefined;
        var at: u64 = index_header_len;
        while (at < length) {
            const want: usize = @intCast(@min(buffer.len, length - at));
            if ((held.readPositionalAll(io, buffer[0..want], at) catch return null) != want) return null;
            builder.checksum = crc32c.update(builder.checksum, buffer[0..want]);
            at += want;
        }
    }
    log.releaseIndex(io);

    const file = log.dir.createFile(io, &segmentName(segment.base_seq, index_extension), .{
        .read = true,
        .truncate = false,
    }) catch return null;
    errdefer file.close(io);
    file.setLength(io, length) catch return null;
    file.writePositionalAll(
        io,
        &placeholderHeader(segment.base_seq, indexed.interval),
        0,
    ) catch return null;

    var writer = file.writer(io, log.index_buf);
    writer.pos = length;
    return .{ .file = file, .writer = writer, .indexed = indexed, .builder = builder };
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

/// The two members of a line the segment layer reads: where the record sits in
/// the sequence, and when the caller said it happened.
const Envelope = struct {
    seq: u64,
    /// Null when the line carries no `at`, or one that is not an integer. Such
    /// a record is one the journal above will refuse; here it only means there
    /// is no timestamp to index it by.
    at: ?i64,
    /// The checksum the line ends with, which the next record carries as its
    /// back-link. Null when the line carries none.
    c: ?u32,
};

/// A line's `seq` and `at`, or null when the line is not an object carrying a
/// sequence number at all.
///
/// A record this package writes begins `{"seq":<digits>,"at":<digits>,`, and
/// that shape is read straight off the bytes, because this runs over every
/// line of the active segment at every open. Anything else — a record written
/// by hand, a member in another order, a line that is not one of ours — goes
/// through `std.json`.
fn envelopeOf(gpa: Allocator, line: []const u8) ?Envelope {
    if (quickEnvelope(line)) |found| return found;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return null;
    if (root != .object) return null;
    const seq = root.object.get("seq") orelse return null;
    if (seq != .integer or seq.integer < 1) return null;
    const at: ?i64 = if (root.object.get("at")) |value|
        (if (value == .integer) value.integer else null)
    else
        null;
    return .{ .seq = @intCast(seq.integer), .at = at, .c = trailingChecksum(line) };
}

/// The `p` a line carries: the checksum of the record before it. Read off
/// the bytes where the shape is the one this package writes, and through
/// `std.json` where it is not.
fn backLinkOf(gpa: Allocator, line: []const u8) ?u32 {
    const opening = ",\"p\":";
    if (std.mem.indexOf(u8, line, opening)) |found| {
        var at = found + opening.len;
        const from = at;
        while (at < line.len and std.ascii.isDigit(line[at])) at += 1;
        if (at != from and at < line.len and (line[at] == ',' or line[at] == '}')) {
            return std.fmt.parseInt(u32, line[from..at], 10) catch null;
        }
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return null;
    if (root != .object) return null;
    const value = root.object.get("p") orelse return null;
    if (value != .integer) return null;
    return std.math.cast(u32, value.integer);
}

/// The `c` a line ends with. It is the last member of every record this
/// package writes, so it is read off the end rather than parsed for.
fn trailingChecksum(line: []const u8) ?u32 {
    const opening = ",\"c\":";
    if (line.len < 2 or line[line.len - 1] != '}') return null;
    var at = line.len - 1;
    var digits: usize = 0;
    while (at > 0 and std.ascii.isDigit(line[at - 1])) : (digits += 1) at -= 1;
    if (digits == 0 or at < opening.len) return null;
    if (!std.mem.eql(u8, line[at - opening.len .. at], opening)) return null;
    return std.fmt.parseInt(u32, line[at .. line.len - 1], 10) catch null;
}

/// The envelope of a line in exactly the shape this package writes, or null to
/// say "ask `std.json`".
fn quickEnvelope(line: []const u8) ?Envelope {
    const seq_prefix = "{\"seq\":";
    const at_prefix = ",\"at\":";
    if (!std.mem.startsWith(u8, line, seq_prefix)) return null;

    var at: usize = seq_prefix.len;
    const seq_from = at;
    while (at < line.len and std.ascii.isDigit(line[at])) at += 1;
    if (at == seq_from) return null;
    const seq = std.fmt.parseInt(u64, line[seq_from..at], 10) catch return null;
    if (seq < 1) return null;

    if (!std.mem.startsWith(u8, line[at..], at_prefix)) return null;
    at += at_prefix.len;
    const at_from = at;
    if (at < line.len and line[at] == '-') at += 1;
    const digits_from = at;
    while (at < line.len and std.ascii.isDigit(line[at])) at += 1;
    if (at == digits_from) return null;
    const stamp = std.fmt.parseInt(i64, line[at_from..at], 10) catch return null;

    // The member has to end where a member ends, or these were the first
    // digits of something else.
    if (at >= line.len or line[at] != ',') return null;
    return .{ .seq = seq, .at = stamp, .c = trailingChecksum(line) };
}

/// The `seq` member of a line, or null when the line is not an object carrying
/// one.
fn seqOf(gpa: Allocator, line: []const u8) ?u64 {
    return (envelopeOf(gpa, line) orelse return null).seq;
}

const Scanned = struct {
    /// Complete, newline-terminated lines seen.
    lines: u64,
    /// Bytes up to and including the last newline.
    complete_bytes: u64,
    /// How much of what follows the last newline was written by somebody:
    /// the bytes up to the last one that is not zero. Zero when the tail is
    /// all zeros, which is space a writer reserved and never filled, not a
    /// record it did not finish.
    partial_bytes: u64,
    /// The lowest and highest `at` over those lines, and `Times.unknown` when
    /// one of them did not carry a readable one.
    times: Times,
    /// The checksum of the last complete record, which the next one carries
    /// as its back-link. The segment header's `root` when there are none.
    chain: u32,
    /// Where the records start: the length of the header line.
    header_bytes: u64,
};

/// Walk a segment's newlines, optionally writing each line's offset and
/// timestamp to an index being built. Memory is one read buffer and one line:
/// nothing grows with the segment.
fn scanSegment(log: *Log, io: Io, segment: Segment, index: ?*IndexSink) OpenError!Scanned {
    var scanned: Scanned = .{
        .lines = 0,
        .complete_bytes = 0,
        .partial_bytes = 0,
        .times = .unknown,
        .chain = 0,
        .header_bytes = 0,
    };
    if (segment.bytes == 0) return scanned;

    const file = try log.dir.openFile(io, &segmentName(segment.base_seq, segment_extension), .{});
    defer file.close(io);
    const buffer = try log.gpa.alloc(u8, log.options.read_buffer_size);
    defer log.gpa.free(buffer);

    var line: Io.Writer.Allocating = .init(log.gpa);
    defer line.deinit();

    var reader = file.reader(io, buffer);
    var offset: u64 = 0;
    var timed = true;
    const cap = log.options.max_record_bytes;
    // How much of the line being read has been seen, and how much of it
    // somebody wrote -- the bytes up to the last one that is not zero. Both
    // are counted rather than measured off what was kept, because a line
    // longer than a record may be is not kept.
    var line_bytes: u64 = 0;
    var line_written: u64 = 0;
    while (offset < segment.bytes) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline| {
            const piece = chunk[0..newline];
            if (writtenLength(piece) != 0) line_written = line_bytes + writtenLength(piece);
            line_bytes += piece.len;
            if (line_bytes > cap) return error.RecordTooLarge;
            line.writer.writeAll(piece) catch return error.OutOfMemory;
            reader.interface.toss(newline + 1);

            if (offset == 0) {
                // The first line says what format the rest of the file is in
                // and what the first record's back-link has to be. A file
                // whose first line is not one is refused rather than read.
                const header = parseSegmentHeader(log.gpa, line.written()) orelse
                    return error.UnsupportedFormat;
                if (header.version != log_format or header.base_seq != segment.base_seq) {
                    return error.UnsupportedFormat;
                }
                scanned.chain = header.root;
                scanned.header_bytes = newline + 1;
            } else {
                const envelope = envelopeOf(log.gpa, line.written());
                const at: ?i64 = if (envelope) |found| found.at else null;
                if (at) |stamp| scanned.times.widen(stamp) else {
                    timed = false;
                }
                if (envelope) |found| {
                    if (found.c) |value| scanned.chain = value;
                }
                if (index) |sink| try sink.record(scanned.lines, offset, at orelse 0);
                scanned.lines += 1;
            }

            line.clearRetainingCapacity();
            line_bytes = 0;
            line_written = 0;
            offset += newline + 1;
            scanned.complete_bytes = offset;
        } else {
            if (writtenLength(chunk) != 0) line_written = line_bytes + writtenLength(chunk);
            // Only as far as a record may be. Past that the line is not one,
            // and the bytes are counted rather than held: a segment ending in
            // a writer's reserved space is mostly zeros, and reading them
            // into memory to find that out would be the whole of the
            // reservation.
            if (line_bytes <= cap) {
                const room = @min(chunk.len, cap - line_bytes);
                line.writer.writeAll(chunk[0..room]) catch return error.OutOfMemory;
            }
            line_bytes += chunk.len;
            reader.interface.toss(chunk.len);
            offset += chunk.len;
        }
    }
    // What is left after the last newline. A record this package writes can
    // hold no zero byte -- `std.json` escapes every control character -- so a
    // run of zeros at the end of a segment is space that was reserved and
    // never written into, and the writer simply carries on there.
    scanned.partial_bytes = line_written;
    // One record with no readable timestamp and the pair says nothing, because
    // a range that does not cover every record cannot be used to skip one.
    if (!timed) scanned.times = .unknown;
    return scanned;
}

/// `bytes` up to and including the last one that is not zero.
fn writtenLength(bytes: []const u8) u64 {
    var at = bytes.len;
    while (at > 0 and bytes[at - 1] == 0) at -= 1;
    return at;
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
    /// How far into each of them the records go. A writer knows that exactly;
    /// a reader beside one does not, and walks to the end of the file and
    /// stops at the first line the writer has not finished.
    limits: []u64,
    at: usize,
    file: ?Io.File,
    reader: Io.File.Reader,
    buffer: []u8,
    line: Io.Writer.Allocating,
    /// Where in the current segment the next line starts.
    position: u64,
    /// Whether the next line is the one that says what the file is.
    at_header: bool,
    /// How long a line may be before it is not a record. A segment with no
    /// newline left in it would otherwise be read into memory whole.
    max_record_bytes: usize,
    /// Whether an unterminated final line in the newest segment is the end of
    /// the walk rather than damage — true for a reader beside a live writer.
    tolerate_partial_tail: bool,

    pub fn deinit(scan: *Scan, io: Io) void {
        if (scan.file) |file| file.close(io);
        scan.line.deinit();
        scan.gpa.free(scan.buffer);
        scan.gpa.free(scan.bases);
        scan.gpa.free(scan.limits);
        scan.* = undefined;
    }

    /// The next line, or null at the end of the log. The bytes are valid until
    /// the next call to `next` or to `deinit`.
    pub fn next(scan: *Scan, io: Io) ScanError!?[]const u8 {
        while (true) {
            if (scan.at >= scan.bases.len) return null;
            // Past the records of this segment: what follows them is space a
            // writer reserved and has not filled, not a record.
            if (scan.position >= scan.limits[scan.at]) {
                if (scan.file) |file| file.close(io);
                scan.file = null;
                scan.at += 1;
                scan.position = 0;
                continue;
            }
            if (scan.file == null) {
                const file = try scan.dir.openFile(io, &segmentName(scan.bases[scan.at], segment_extension), .{});
                scan.file = file;
                scan.reader = file.reader(io, scan.buffer);
                if (scan.position != 0) try scan.reader.seekTo(scan.position);
                scan.at_header = scan.position == 0;
            }
            scan.line.clearRetainingCapacity();
            const streamed = scan.reader.interface.streamDelimiterLimit(
                &scan.line.writer,
                '\n',
                .limited(scan.max_record_bytes + 1),
            ) catch |err| switch (err) {
                error.ReadFailed => return scan.reader.err.?,
                error.WriteFailed => return error.OutOfMemory,
                // No newline within the length a record may be: whatever is
                // there, it is not one of ours.
                error.StreamTooLong => return error.RecordTooLarge,
            };
            // What follows what was streamed is the newline, or nothing at
            // all: `streamDelimiterEnding` leaves the delimiter buffered when
            // it found one and leaves the buffer empty when it ran out of
            // file. Both have to be told apart by the *byte*, not by whether
            // there is one. A writer in another process may have appended
            // since the line ran out, in which case there is a byte and it is
            // the rest of the record — and taking it for the newline would
            // hand back half a record and leave the walk one byte out for
            // every record after it.
            const ending = scan.reader.interface.peekByte() catch |err| switch (err) {
                error.EndOfStream => null,
                error.ReadFailed => return scan.reader.err.?,
            };
            const terminated = ending == @as(?u8, '\n');
            if (terminated) {
                scan.reader.interface.toss(1);
                scan.position += streamed + 1;
                if (scan.at_header) {
                    // The first line of a file says what the rest of it is.
                    // A walk that starts there reads it and checks it; one
                    // that starts at an offset the index gave is already past
                    // it, and the open that gave it the offset checked it.
                    scan.at_header = false;
                    const header = parseSegmentHeader(scan.gpa, scan.line.written()) orelse
                        return error.UnsupportedFormat;
                    if (header.version != log_format or header.base_seq != scan.bases[scan.at]) {
                        return error.UnsupportedFormat;
                    }
                    continue;
                }
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
    const limits = try log.gpa.alloc(u64, segments.len);
    errdefer log.gpa.free(limits);
    // A reader has no committed length to go on -- the writer is still
    // appending -- so it walks to the end of the file and lets the missing
    // newline end it.
    const unbounded = log.options.access == .read;
    for (segments, bases, limits) |segment, *base, *limit| {
        base.* = segment.base_seq;
        limit.* = if (unbounded) std.math.maxInt(u64) else segment.bytes;
    }

    const buffer = try log.gpa.alloc(u8, log.options.read_buffer_size);
    errdefer log.gpa.free(buffer);

    return .{
        .gpa = log.gpa,
        .dir = log.dir,
        .bases = bases,
        .limits = limits,
        .at = 0,
        .file = null,
        .reader = undefined,
        .buffer = buffer,
        .line = .init(log.gpa),
        .position = position,
        .at_header = false,
        .max_record_bytes = log.options.max_record_bytes,
        .tolerate_partial_tail = log.options.access == .read,
    };
}

/// A `Scan` positioned at the first record after `cursor`, as close to it as
/// the indexes allow.
///
/// The walk may begin a little before it — a caller with a cursor drops what it
/// has already seen — but never after it.
pub fn scanFrom(log: *Log, io: Io, cursor: u64, may_write: bool) ScanError!Scan {
    if (log.segments.items.len == 0) return log.scanOver(&.{}, 0);

    // Saturating: a cursor of every one is a reader past the end of any log
    // this package can write, and it walks nothing rather than wrapping.
    const wanted = cursor +| 1;
    var first: usize = 0;
    for (log.segments.items, 0..) |segment, i| {
        if (segment.base_seq <= wanted) first = i;
    }
    if (log.segments.items[first].last_seq <= cursor and first + 1 < log.segments.items.len) {
        first += 1;
    }
    const position = log.indexedOffset(io, first, wanted, may_write) orelse 0;
    return log.scanOver(log.segments.items[first..], position);
}

//========================================================================
// Lookup by time.
//========================================================================

/// The lowest sequence number whose record carries an `at` at or after `want`,
/// or null when no record in the log does.
///
/// The timestamps are not assumed to rise with the sequence numbers, so this
/// is a search and not a bisection: every segment whose highest `at` reaches
/// `want` is looked inside, oldest first, and the first record found wins. A
/// segment whose highest is below `want` holds nothing that can qualify and is
/// skipped whole — without its file being opened.
///
/// What it costs: for a sealed segment, the index, which is rebuilt first if
/// it is missing or stale. For the active segment, whose index is not sealed
/// yet, a walk of the segment — bounded by `Options.max_segment_bytes`, and
/// only when its own timestamps say a record could be in there.
pub fn seqAtOrAfter(log: *Log, io: Io, want: i64) OpenError!?u64 {
    for (log.segments.items, 0..) |*segment, i| {
        if (segment.count() == 0) continue;
        const active = i + 1 == log.segments.items.len;
        if (!segment.times.known() and !active) {
            // A sealed segment whose index did not describe it at open. Build
            // one now and keep what it says, so a second lookup is free.
            if (log.provenIndex(io, i, true)) |indexed| segment.times = indexed.times;
        }
        if (segment.times.known()) {
            if (segment.times.highest < want) continue;
            if (segment.times.lowest >= want) return segment.base_seq;
            if (!active) {
                if (try log.indexedSeqAtOrAfter(io, i, want)) |seq| return seq;
            }
        }
        if (try log.scannedSeqAtOrAfter(io, segment.*, want, segment.header_bytes, segment.base_seq)) |seq| return seq;
    }
    return null;
}

/// The first sequence number at or after `want` inside one segment, read from
/// the timestamps in its index rather than from the segment itself.
fn indexedSeqAtOrAfter(log: *Log, io: Io, at: usize, want: i64) OpenError!?u64 {
    const segment = log.segments.items[at];
    const indexed = log.provenIndex(io, at, true) orelse return null;
    if (indexed.entries == 0) return null;
    const file = log.holdIndex(io, segment.base_seq) orelse return null;

    if (indexed.times.rising) {
        // The timestamps do not fall, so the entry to start from is found by
        // halving rather than by reading them all.
        var low: u64 = 0;
        var high: u64 = indexed.entries;
        var from: ?IndexEntry = null;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = log.indexEntryAt(io, file, middle) orelse return null;
            if (entry.at < want) {
                from = entry;
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (from) |entry| {
            if (indexed.interval == 0) return entry.seq + 1;
            // One entry covers a run of records, so the answer is inside the
            // run that starts here: at most `interval` bytes of segment.
            return log.scannedSeqAtOrAfter(io, segment, want, entry.offset, entry.seq);
        }
        const first = log.indexEntryAt(io, file, 0) orelse return null;
        if (indexed.interval == 0) return first.seq;
        return log.scannedSeqAtOrAfter(io, segment, want, first.offset, first.seq);
    }

    if (indexed.interval != 0) {
        // Nothing to halve and nothing complete to read: the entries name
        // some of the records, and any of the others could be the answer.
        return null;
    }
    var slot: u64 = 0;
    while (slot < indexed.entries) : (slot += 1) {
        const entry = log.indexEntryAt(io, file, slot) orelse return null;
        if (entry.at >= want) return entry.seq;
    }
    return null;
}

/// The same answer read out of the segment itself, for the active segment and
/// for one no index describes. A record with no readable `at` is
/// `error.CorruptRecord`: a lookup by time cannot step over a record that has
/// none.
fn scannedSeqAtOrAfter(
    log: *Log,
    io: Io,
    segment: Segment,
    want: i64,
    from_offset: u64,
    from_seq: u64,
) OpenError!?u64 {
    var scan = try log.scanOver(&.{segment}, from_offset);
    defer scan.deinit(io);
    var seq = from_seq;
    while (try scan.next(io)) |line| : (seq += 1) {
        const envelope = envelopeOf(log.gpa, line) orelse return error.CorruptRecord;
        const at = envelope.at orelse return error.CorruptRecord;
        if (at >= want) return seq;
    }
    return null;
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
pub fn appendLine(log: *Log, io: Io, bytes: []const u8, at: i64, checksum: u32) AppendError!void {
    try log.stageLine(io, bytes, at, checksum);
    try log.commit(io);
}

/// The checksum the next record has to carry as its back-link: the newest
/// record's, or the active segment's chain root when it holds none.
pub fn chainTip(log: *const Log) u32 {
    return log.chain;
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
pub fn stageLine(log: *Log, io: Io, bytes: []const u8, at: i64, checksum: u32) AppendError!void {
    if (log.active == null) return error.ReadOnly;
    var segment = &log.segments.items[log.segments.items.len - 1];

    const needed = bytes.len + 1;
    const over_bytes = segment.bytes + needed > log.options.max_segment_bytes;
    const over_records = if (log.options.max_segment_records) |limit| segment.count() >= limit else false;
    if (segment.count() > 0 and (over_bytes or over_records)) {
        // The rotation seals the segment being left, so the records staged
        // into it are durable before the new one is named. The chain carries
        // across it: a rotation is not a break in the records.
        try log.rotate(io);
        segment = &log.segments.items[log.segments.items.len - 1];
    }

    try log.reserveAhead(io, needed);

    const offset = segment.bytes;
    const active = &log.active.?;
    try active.writer.interface.writeAll(bytes);
    try active.writer.interface.writeByte('\n');

    try active.builder.record(
        &active.index_writer,
        segment.count(),
        offset,
        at,
    );
    segment.bytes += needed;
    segment.last_seq += 1;
    segment.times.widen(at);
    log.chain = checksum;
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
    if (log.options.sync == .always) try log.syncActive(io);
}

/// Make the active segment's bytes durable at the level the file's own shape
/// allows: the contents alone when the write went into space the file already
/// had, and the whole file when it grew.
fn syncActive(log: *Log, io: Io) Io.File.SyncError!void {
    const active = &log.active.?;
    const segment = log.segments.items[log.segments.items.len - 1];
    const level: durable.Level = if (segment.bytes <= active.preallocated) .contents else .whole;
    return durable.sync(io, active.file, level);
}

/// Seal the active segment and start a new one named after the record that
/// will go into it.
fn rotate(log: *Log, io: Io) AppendError!void {
    const segment = log.segments.items[log.segments.items.len - 1];
    {
        const active = &log.active.?;
        try active.writer.interface.flush();
        try log.trimPreallocation(io);
        if (log.options.sync != .never) try durable.sync(io, active.file, .whole);
        try active.index_writer.interface.flush();
        // A seal that cannot be written leaves an index the next open reads
        // as stale and rebuilds, which is a cost and not a wrong answer -- but
        // a disk that has just refused a write is not something to pass over
        // in silence on the way to writing more.
        try sealIndex(io, active.index_file, .{
            .segment_bytes = segment.bytes,
            .base_seq = segment.base_seq,
            .records = segment.count(),
            .times = segment.times,
            .interval = @intCast(active.builder.interval),
            .entries_checksum = ~active.builder.checksum,
        });
    }
    log.closeActive(io);

    const base_seq = segment.last_seq + 1;
    // The chain carries on across the rotation, so the new file's first
    // record links to the last record of the old one.
    const started = try log.startSegment(io, base_seq, log.chain);
    log.active = started.active;
    var fresh: Segment = .named(base_seq);
    fresh.header_bytes = started.header_bytes;
    fresh.bytes = started.header_bytes;
    try log.segments.append(log.gpa, fresh);
}

/// A segment file just created, and where its records begin.
const Started = struct {
    active: Active,
    header_bytes: u64,
};

/// Create a segment file, write the line that says what it is, and open the
/// index beside it. The returned `Active` is positioned after the header.
fn startSegment(log: *Log, io: Io, base_seq: u64, root: u32) AppendError!Started {
    const file = try log.dir.createFile(io, &segmentName(base_seq, segment_extension), .{
        .read = true,
        .truncate = true,
    });
    errdefer file.close(io);

    var writer = file.writer(io, log.write_buf);
    var buffer: [96]u8 = undefined;
    const header: SegmentHeader = .{ .version = log_format, .base_seq = base_seq, .root = root };
    try writer.interface.writeAll(header.line(&buffer));
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    if (log.options.sync != .never) try durable.sync(io, file, .whole);
    try log.syncDir(io);
    const header_bytes = writer.pos;

    // Readable as well as writable: `indexedOffset` reads the live index back
    // through this handle, which is what turns a seek into the segment being
    // written to into a read rather than a scan of it.
    const index_file = try log.dir.createFile(io, &segmentName(base_seq, index_extension), .{
        .read = true,
        .truncate = true,
    });
    errdefer index_file.close(io);
    var index_writer = index_file.writer(io, log.index_buf);
    try index_writer.interface.writeAll(&placeholderHeader(base_seq, log.options.index_interval_bytes));

    log.chain = root;
    return .{
        .header_bytes = header_bytes,
        .active = .{
            .file = file,
            .writer = writer,
            .index_file = index_file,
            .index_writer = index_writer,
            .preallocated = header_bytes,
            .builder = .init(base_seq, log.options.index_interval_bytes),
        },
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
        segment.times = scanned.times;
        segment.header_bytes = scanned.header_bytes;
        log.chain = scanned.chain;
        return;
    }

    // A file with nothing in it is a segment whose creation did not finish:
    // the name is on the disk and the line that says what it is is not. It is
    // written again rather than read.
    if (try log.fileLength(io, &name) == 0) {
        const started = try log.startSegment(io, segment.base_seq, freshRoot(io));
        segment.bytes = started.header_bytes;
        segment.header_bytes = started.header_bytes;
        segment.last_seq = segment.base_seq - 1;
        segment.times = .unknown;
        log.active = started.active;
        return;
    }

    const file = try log.dir.createFile(io, &name, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    segment.bytes = try file.length(io);

    // A close seals the active segment's index with the exact length it
    // describes, and an index that describes this file at this length was
    // built from these bytes: the offsets are right, and the last record it
    // names ends the file, which is the same proof a repair pass would go and
    // get. So a clean restart takes it and the scan is skipped altogether.
    if (try log.resumeIndex(io, segment.*)) |taken| {
        var resumed = taken;
        errdefer resumed.file.close(io);
        // The header line and the chain still have to be read, but that is
        // one line and not the segment.
        const head = try log.readSegmentHeader(io, segment.*);
        segment.header_bytes = head.header_bytes;
        segment.last_seq = segment.base_seq + resumed.indexed.count - 1;
        segment.times = resumed.indexed.times;
        log.chain = try log.lastChecksum(io, segment.*, head.root);
        var writer = file.writer(io, log.write_buf);
        writer.pos = segment.bytes;
        log.active = .{
            .file = file,
            .writer = writer,
            .index_file = resumed.file,
            .index_writer = resumed.writer,
            .preallocated = segment.bytes,
            .builder = resumed.builder,
        };
        return;
    }

    // The index has no durability of its own, so the active segment's is
    // rebuilt here, from the bytes that are actually in the file. It is opened
    // readable too: `indexedOffset` reads the live index back through this
    // handle rather than scanning the segment.
    const index_file = try log.dir.createFile(io, &segmentName(segment.base_seq, index_extension), .{ .read = true, .truncate = true });
    errdefer index_file.close(io);
    var index_writer = index_file.writer(io, log.index_buf);
    try index_writer.interface.writeAll(&placeholderHeader(segment.base_seq, log.options.index_interval_bytes));
    var builder: Builder = .init(segment.base_seq, log.options.index_interval_bytes);
    var sink: IndexSink = .{ .builder = &builder, .writer = &index_writer };

    const scanned = try log.scanSegment(io, segment.*, &sink);
    if (scanned.complete_bytes == 0) {
        // Not one whole line: the file was created and the line that says
        // what it is never reached the disk. It is written again, and
        // whatever fragment was there is what was dropped.
        if (log.options.on_truncated == .fail) return error.TruncatedRecord;
        log.dropped_bytes = @intCast(scanned.partial_bytes);
        index_file.close(io);
        file.close(io);
        const started = try log.startSegment(io, segment.base_seq, freshRoot(io));
        segment.bytes = started.header_bytes;
        segment.header_bytes = started.header_bytes;
        segment.last_seq = segment.base_seq - 1;
        segment.times = .unknown;
        log.active = started.active;
        return;
    }

    // Space reserved and never written into is not a record the writer did
    // not finish: the writer carries on into it, and nothing was dropped.
    var preallocated = segment.bytes;
    if (scanned.partial_bytes != 0) switch (log.options.on_truncated) {
        .fail => return error.TruncatedRecord,
        .drop => {
            log.dropped_bytes = @intCast(scanned.partial_bytes);
            try file.setLength(io, scanned.complete_bytes);
            preallocated = scanned.complete_bytes;
        },
    };
    segment.bytes = scanned.complete_bytes;
    try index_writer.interface.flush();
    segment.last_seq = segment.base_seq + scanned.lines - 1;
    segment.times = scanned.times;
    segment.header_bytes = scanned.header_bytes;
    log.chain = scanned.chain;

    var writer = file.writer(io, log.write_buf);
    writer.pos = segment.bytes;
    log.active = .{
        .file = file,
        .writer = writer,
        .index_file = index_file,
        .index_writer = index_writer,
        .preallocated = preallocated,
        .builder = builder,
    };
}

/// The first line of a segment, which says what format its records are in and
/// what the first of them links back to.
fn readSegmentHeader(log: *Log, io: Io, segment: Segment) OpenError!struct { root: u32, header_bytes: u64 } {
    const line = try log.lineAt(io, segment, 0);
    defer log.gpa.free(line.bytes);
    if (!line.terminated) return error.UnsupportedFormat;
    const header = parseSegmentHeader(log.gpa, line.bytes) orelse return error.UnsupportedFormat;
    if (header.version != log_format or header.base_seq != segment.base_seq) return error.UnsupportedFormat;
    return .{ .root = header.root, .header_bytes = line.bytes.len + 1 };
}

/// The checksum of a segment's last record, which the next one links back to.
/// `root` is the answer for a segment holding no records.
fn lastChecksum(log: *Log, io: Io, segment: Segment, root: u32) OpenError!u32 {
    if (segment.count() == 0) return root;
    const line = try log.lastLine(io, segment);
    defer log.gpa.free(line.bytes);
    if (!line.terminated) return error.TruncatedRecord;
    const envelope = envelopeOf(log.gpa, line.bytes) orelse return error.CorruptRecord;
    return envelope.c orelse return error.CorruptRecord;
}

/// Keep the active segment zero-filled `Options.preallocate_bytes` ahead of
/// the record about to go into it.
///
/// A file that is not growing costs less to make durable -- the size in its
/// inode does not have to go down with the bytes -- which is the whole of the
/// reason to do this, and is why `syncActive` asks for the cheaper flush
/// exactly while the writes land inside what was reserved. The cost is the
/// zeros: a segment is written twice, once as zeros and once as records.
///
/// The reserved space is never past `Options.max_segment_bytes`, so a segment
/// is no larger on the disk than it was without this, and a rotation or a
/// close cuts back whatever is left of it.
fn reserveAhead(log: *Log, io: Io, needed: u64) AppendError!void {
    const ahead = log.options.preallocate_bytes;
    if (ahead == 0) return;
    const active = &log.active.?;
    const segment = log.segments.items[log.segments.items.len - 1];
    if (segment.bytes + needed <= active.preallocated) return;

    const target = @min(
        @max(log.options.max_segment_bytes, segment.bytes + needed),
        segment.bytes + needed + ahead,
    );
    if (target <= active.preallocated) return;

    var zeros: [8192]u8 = @splat(0);
    var at = @max(active.preallocated, segment.bytes);
    while (at < target) {
        const want: usize = @intCast(@min(zeros.len, target - at));
        try active.file.writePositionalAll(io, zeros[0..want], at);
        at += want;
    }
    active.preallocated = target;
}

/// Cut the reserved space back to the records, so that a sealed segment is
/// exactly its records and a closed log leaves no zeros behind.
fn trimPreallocation(log: *Log, io: Io) Io.File.SetLengthError!void {
    const active = &log.active.?;
    const segment = log.segments.items[log.segments.items.len - 1];
    if (active.preallocated <= segment.bytes) return;
    try active.file.setLength(io, segment.bytes);
    active.preallocated = segment.bytes;
}

/// Create an empty segment file and make its name durable.
fn createSegment(log: *Log, io: Io, base_seq: u64) OpenError!void {
    if (log.options.access == .read) return error.ReadOnly;
    const file = try log.dir.createFile(io, &segmentName(base_seq, segment_extension), .{ .truncate = false });
    file.close(io);
    try log.syncDir(io);
    try log.segments.append(log.gpa, .named(base_seq));
}

/// A fresh chain root: the number a record from another file, or from an
/// earlier life of this one, will not be carrying.
fn freshRoot(io: Io) u32 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u32, &bytes, .little);
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
    return syncDirHandle(io, log.dir);
}

fn syncDirHandle(io: Io, dir: Io.Dir) Io.File.SyncError!void {
    if (!can_sync_dir) return;
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    durable.sync(io, as_file, .whole) catch |err| switch (err) {
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
        if (log.options.sync != .never) try durable.sync(io, file, .whole);
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
    var offset = segment.header_bytes;
    var at = segment.base_seq;
    while (try scan.next(io)) |_| : (at += 1) {
        if (at > seq) break;
        offset = scan.position;
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
        // one named for the record that comes next carries the sequence. Its
        // chain starts again, because no record in it links to one before it.
        const chain = log.chain;
        log.closeActive(io);
        const started = try log.startSegment(io, keep_from, freshRoot(io));
        var active = started.active;
        active.writer.interface.flush() catch {};
        active.file.close(io);
        active.index_file.close(io);
        log.chain = chain;
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
        var wrote_header = false;
        while (try scan.next(io)) |line| : (seq += 1) {
            if (seq < keep_from) continue;
            if (!wrote_header) {
                // Records are copied byte for byte, so the new file's chain
                // has to root where the first of them links back to. That
                // number is in the record itself.
                const root = backLinkOf(log.gpa, line) orelse return error.CorruptRecord;
                var buffer: [96]u8 = undefined;
                const header: SegmentHeader = .{
                    .version = log_format,
                    .base_seq = keep_from,
                    .root = root,
                };
                try writer.interface.writeAll(header.line(&buffer));
                try writer.interface.writeByte('\n');
                wrote_header = true;
            }
            try writer.interface.writeAll(line);
            try writer.interface.writeByte('\n');
        }
        try writer.interface.flush();
        try durable.sync(io, out, .whole);
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
        try durable.sync(io, file, .whole);
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
// Copying a running log.
//========================================================================

pub const BackupError = OpenError || Io.Dir.RealPathFileAllocError || error{BackupInPlace};

/// Copy a consistent view of the log into the directory `dest_path`, creating
/// it if it is not there, and report the newest sequence number the copy
/// holds.
///
/// What "consistent" means here, exactly:
///
/// * Every sealed segment goes whole. A sealed segment was made durable by the
///   rotation that left it and cannot change again.
/// * The newest segment goes up to its last complete record *at the moment of
///   the call* — its length is measured and its newlines walked here, not
///   taken from what this process last read — so the copy ends at a record
///   boundary whoever is appending and however far they have got.
/// * The snapshot is copied first, so it can never name a record the copy does
///   not hold.
/// * The sealed indexes go with their segments, because they describe exactly
///   the bytes that were copied. The newest segment's does not: it describes
///   bytes that are still arriving, so the copy is opened without it and
///   builds its own, which is one scan of one segment.
/// * The lock is not copied. It is this directory's, and the copy makes its
///   own the first time it is opened for writing.
///
/// So the copy is a *prefix* of the log: every record in it is a record that
/// was in the log, in order, with no gap, and it opens as a journal. Records
/// appended after the call started may or may not be in it.
///
/// Taken by the writer, under the journal's lock, nothing can move underneath
/// it. Taken by a reader beside a live writer, the only thing that can is a
/// `compact` or a `dropSegmentsBefore` unlinking a segment while it is being
/// read, which comes back as an error rather than as a copy with a hole in it:
/// take it again.
pub fn backup(log: *Log, io: Io, dest_path: []const u8) BackupError!u64 {
    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, dest_path);
    var dest = try cwd.openDir(io, dest_path, .{ .iterate = true });
    defer dest.close(io);
    // Copying a directory over itself would truncate the segments it was
    // reading. Nothing else here can tell the two apart.
    if (try log.sameDirectory(io, dest)) return error.BackupInPlace;
    if (log.segments.items.len == 0) return 0;

    // Everything this process has written goes into the files before anything
    // is read back out of them.
    if (log.active) |*active| {
        try active.writer.interface.flush();
        try active.index_writer.interface.flush();
    }

    _ = try log.copyFile(io, dest, snapshot_name, null);

    const newest = log.segments.items.len - 1;
    for (log.segments.items[0..newest]) |segment| {
        const name = segmentName(segment.base_seq, segment_extension);
        if (!try log.copyFile(io, dest, &name, segment.bytes)) return error.FileNotFound;
        _ = try log.copyFile(io, dest, &segmentName(segment.base_seq, index_extension), null);
    }

    // The newest segment, measured now: a writer in another process may be
    // part-way through a record, and the bytes after its last newline are not
    // one yet.
    var last = log.segments.items[newest];
    const name = segmentName(last.base_seq, segment_extension);
    last.bytes = try log.fileLength(io, &name);
    const scanned = try log.scanSegment(io, last, null);
    if (!try log.copyFile(io, dest, &name, scanned.complete_bytes)) return error.FileNotFound;

    try syncDirHandle(io, dest);
    if (scanned.lines == 0) return last.base_seq - 1;
    return last.base_seq + scanned.lines - 1;
}

/// Copy `name` into `dest`, either the first `bytes` of it or all of it.
/// False when there is no such file, which is not an error for a snapshot or
/// an index — neither is part of the log.
fn copyFile(log: *Log, io: Io, dest: Io.Dir, name: [:0]const u8, bytes: ?u64) OpenError!bool {
    // The filesystem's own copy first, where there is one. A sealed segment
    // is bytes that will never change again, and sharing their extents makes
    // a backup of a year of them the size of a directory entry.
    if (bytes == null and clone.available) {
        dest.deleteFile(io, name) catch {};
        if (clone.whole(io, log.dir, dest, name)) return true;
    }

    const from = log.dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer from.close(io);
    const length = bytes orelse try from.length(io);

    const to = try dest.createFile(io, name, .{ .truncate = true });
    defer to.close(io);

    // A prefix of a file -- the newest segment, up to its last whole record
    // -- can still go through the filesystem where the platform takes a
    // length.
    if (clone.range(to, from, length)) {
        try durable.sync(io, to, .whole);
        return true;
    }

    const chunk = try log.gpa.alloc(u8, log.options.read_buffer_size);
    defer log.gpa.free(chunk);

    var at: u64 = 0;
    while (at < length) {
        const want: usize = @intCast(@min(chunk.len, length - at));
        const read = try from.readPositionalAll(io, chunk[0..want], at);
        // The file was longer a moment ago. Something is rewriting the
        // directory underneath this copy.
        if (read == 0) return error.TruncatedRecord;
        try to.writePositionalAll(io, chunk[0..read], at);
        at += read;
    }
    try durable.sync(io, to, .whole);
    return true;
}

/// Whether `dest` is the directory this log lives in. Failure to establish
/// identity stops the copy: treating an unknown destination as different can
/// open a source segment through the destination handle with truncation.
fn sameDirectory(log: *Log, io: Io, dest: Io.Dir) Io.Dir.RealPathFileAllocError!bool {
    var arena: std.heap.ArenaAllocator = .init(log.gpa);
    defer arena.deinit();
    const here = try log.dir.realPathFileAlloc(io, ".", arena.allocator());
    const there = try dest.realPathFileAlloc(io, ".", arena.allocator());
    return std.mem.eql(u8, here, there);
}

//========================================================================
// Teardown.
//========================================================================

pub fn deinit(log: *Log, io: Io) void {
    if (log.active) |*active| {
        active.writer.interface.flush() catch {};
        log.trimPreallocation(io) catch {};
        if (log.options.sync != .never) durable.sync(io, active.file, .whole) catch {};
        active.index_writer.interface.flush() catch {};
        // Leave the active index stamped with the length it describes, so that
        // the next open can take it rather than rebuild it.
        const segment = log.segments.items[log.segments.items.len - 1];
        if (segment.bytes != 0) sealIndex(io, active.index_file, .{
            .segment_bytes = segment.bytes,
            .base_seq = segment.base_seq,
            .records = segment.count(),
            .times = segment.times,
            .interval = @intCast(active.builder.interval),
            .entries_checksum = ~active.builder.checksum,
        }) catch {};
        active.file.close(io);
        active.index_file.close(io);
        log.active = null;
    }
    log.releaseIndex(io);
    if (log.lock_file) |file| file.close(io);
    log.segments.deinit(log.gpa);
    log.dir.close(io);
    log.gpa.free(log.write_buf);
    log.gpa.free(log.index_buf);
    log.gpa.free(log.path);
    log.* = undefined;
}
