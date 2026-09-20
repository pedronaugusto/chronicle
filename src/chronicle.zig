//! chronicle — an append-only, replayable event log.
//!
//! One JSON object per line, each carrying a sequence number, a timestamp, a
//! schema version, the checksum of the record before it and its own, under a
//! line that says what the file is:
//!
//! ```
//! {"chronicle":1,"base":1,"root":3116291790}
//! {"seq":1,"at":1700000000000,"v":1,"p":3116291790,"ev":{"created":{"id":7}},"c":2544158864}
//! {"seq":2,"at":1700000000100,"v":1,"p":2544158864,"ev":{"renamed":{"id":7,"to":"b"}},"c":3032764768}
//! ```
//!
//! The lines live in a directory of segment files, each named after the first
//! record in it, beside an index that turns a cursor into a seek and a lock
//! that keeps a second writer out. Opening a journal reads the newest segment
//! and one line of each older one, not the log; folding one streams from the
//! disk a record at a time.
//!
//! The log is the state. Any number of readers fold the same records into
//! whatever shape they need, from disk at startup and live afterwards, and a
//! snapshot bounds how far back a fold has to start.
//!
//! Everything here is generic over one `Event` type, which may be any type
//! `std.json` can both stringify and parse — a tagged union is the expected
//! shape, because it gives each record a name on disk and an exhaustive
//! `switch` in the fold.
//!
//! See `Journal` for the API, and README.md for the durability promises.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Log = @import("log.zig");
const durable = @import("durable.zig");
const crc32c = @import("crc32c.zig");

/// What `Journal.open` does with a final line the previous writer did not
/// finish — the normal shape of a crash during `append`.
pub const OnTruncated = Log.OnTruncated;

/// Whether a journal may be written to, and so whether it takes the lock.
pub const Access = Log.Access;

/// How often `append` makes the bytes it wrote durable. README.md states the
/// promise each level carries, per platform.
pub const Sync = Log.Sync;

/// The call a durable write makes on a platform.
pub const Flush = durable.Flush;

/// What `Options.sync = .always` issues here, which is what a returned
/// sequence number survives here. README.md's durability table is the same
/// three answers in words.
pub const flush: Flush = durable.flush;

/// The file inside a journal directory that a writer holds its advisory lock
/// on. It is never read or written.
pub const lock_name = Log.lock_name;
/// The file inside a journal directory that `Journal.snapshot` writes.
pub const snapshot_name = Log.snapshot_name;
/// The extensions of the two files that make up one segment.
pub const segment_extension = Log.segment_extension;
pub const index_extension = Log.index_extension;
/// A named reader's cursor file is its name plus this. See `Journal.Tailer`.
pub const cursor_extension = Log.cursor_extension;

/// How much of a journal `open` reads back before it returns.
pub const Verify = enum {
    /// The newest segment and one line of each older one, which is enough to
    /// know the sequence runs from the first record to the last without a gap.
    /// The cost is one segment.
    quick,
    /// Every record of every segment, through the checks a replay makes: the
    /// checksum, the envelope, the schema version and the sequence. The cost
    /// is the log, which is why it is not the default.
    full,
};

/// The name of the segment file whose first record is `base_seq`, relative to
/// the journal's directory. Exposed because a journal's directory is meant to
/// be read with `tail -f` and with your eyes.
pub fn segmentName(base_seq: u64) [Log.name_digits + segment_extension.len:0]u8 {
    return Log.segmentName(base_seq, segment_extension);
}

/// The version stamped into the two documents that live beside the log: the
/// snapshot and a named reader's cursor. Neither is part of the log — one is
/// a copy of a fold and the other is a number a reader keeps — but both are
/// read back by this package, so both say which shape they are in and an
/// unknown one is `error.UnsupportedFormat` rather than a guess.
pub const document_format: u32 = 1;

/// The CRC32C of the bytes a record's checksum covers: its line up to, but not
/// including, the `,"c":` that carries the checksum.
///
/// `append` writes it and every read verifies it. It is public so that a tool
/// reading a segment with something other than this package can check one.
pub fn checksum(covered: []const u8) u32 {
    return crc32c.hash(covered);
}

/// An append-only log of `Event` values.
///
/// The returned type owns a directory, the newest segment's files, an advisory
/// lock, a bounded tail of records in memory and one mutex. Create it with
/// `open` or `openWithSnapshot` and release it with `close`, or with the
/// best-effort `deinit` where an error cannot be returned.
///
/// `Event` must round-trip through `std.json`: `std.json.Stringify.value` must
/// accept it and `std.json.parseFromSlice` must read back what was written. A
/// tagged union of structs is the expected shape.
pub fn Journal(comptime Event: type) type {
    return struct {
        const Self = @This();

        // Three fields are part of the API and are documented as such. The
        // rest, below the divider, are the journal's own bookkeeping: reading
        // them is reading an implementation, and writing them is undefined.

        /// How many unterminated bytes `open` dropped from the end of the
        /// newest segment. Zero unless a previous writer died mid-record, and
        /// zero when `Options.on_truncated` is `.fail`, which fails instead.
        dropped_bytes: usize,
        /// Whether an `append` has failed to reach the disk. Once true it stays
        /// true until `reconcile`, and every `append` and `compact` is refused;
        /// see `AppendError.PersistenceFailed`.
        persistence_failed: bool,
        /// The options `open` was given, unchanged.
        options: Options,

        //-------------------------------------------------------------- internals

        /// The allocator every allocation comes from. Owned by the caller; the
        /// journal never outlives it.
        gpa: Allocator,
        /// The segments, the indexes, the lock and the directory.
        log: Log,
        /// The newest records, oldest first. Each owns its memory through the
        /// arena at the same position in `tail_arenas`, which is released when
        /// the record falls out of the tail.
        tail: std.ArrayList(Record),
        tail_arenas: std.ArrayList(std.heap.ArenaAllocator),
        /// What the tail's records add up to, for `Options.tail_bytes`.
        tail_bytes: usize,
        /// Reset once per record while reading records back; never holds
        /// anything a caller can see.
        scratch: std.heap.ArenaAllocator,
        sinks: std.ArrayList(Sink),
        mutex: Io.Mutex,
        changed: Io.Condition,
        /// Bumped by `nudge`: a wake with no record behind it.
        nudges: u64,
        /// The sequence number of the newest record, or zero. Read it with
        /// `lastSeq`, which takes the lock.
        seq: u64,

        /// One entry of the log, as held in memory.
        ///
        /// Every slice in a record — `bytes`, and anything `event` points at —
        /// belongs either to the journal's tail or to the `Replay` that
        /// produced it. See `Window` and `Replay.next` for how long each lasts.
        pub const Record = struct {
            /// Position in the log. The first record of a journal that has
            /// never been compacted is 1, and it rises by one per record. It is
            /// written as a JSON integer, so `maxInt(i64)` is the last one a
            /// journal can hold; see `AppendError.SequenceExhausted`.
            seq: u64,
            /// Whatever the appender passed as `at`. chronicle never reads a
            /// clock; milliseconds since the Unix epoch is the intended unit.
            at: i64,
            /// The schema version this record was written at. Equal to the
            /// journal's `Options.schema_version` unless it was written by an
            /// older writer and read back through `Options.migrate` or the
            /// `unknown` arm.
            version: u32,
            /// The parsed event.
            event: Event,
            /// This record's exact line on disk, without the trailing newline.
            /// Appending it to a stream reproduces the durable form with no
            /// re-encoding.
            bytes: []const u8,
        };

        /// The records after a cursor that memory still holds.
        ///
        /// `records` is valid until the tail evicts them, which the next
        /// `append` may do: treat it as a borrow that ends at the next call
        /// into the journal by anyone. Copy what you need, or take the records
        /// through a `Sink`, which is called before anything is evicted.
        pub const Window = struct {
            /// The records, oldest first. Empty when the cursor is caught up.
            records: []const Record,
            /// Whether `records` begins at the record straight after the
            /// cursor. False means the tail no longer reaches back that far and
            /// the records in between are on the disk only: `replay` reads
            /// them, and `subscribeFrom` folds them for you.
            complete: bool,
        };

        /// One record for `appendAll`: what `append` takes as two arguments.
        pub const Entry = struct {
            /// Stored as given; chronicle never reads a clock.
            at: i64,
            event: Event,
        };

        /// A fold, called once per record: for the records the journal replays
        /// when it subscribes, and then for each one appended, in sequence
        /// order, with the journal's lock held.
        ///
        /// The callback must not call back into the journal, and must not
        /// retain the `Record` or anything inside it past the call.
        pub const Sink = struct {
            ctx: *anyopaque,
            f: *const fn (*anyopaque, Record) void,
        };

        /// What a `migrate` hook may fail with. `Unmigratable` means the hook
        /// knows the version and refuses it; it reaches the caller unchanged.
        pub const MigrateError = error{ OutOfMemory, Unmigratable };

        /// Translates a record written at an older schema version into the
        /// current `Event`.
        ///
        /// `value` is the record's `ev` member, parsed into the arena that owns
        /// the record being built: an `Event` the hook returns may borrow from
        /// it, and lasts exactly as long as that record does.
        pub const Migrate = *const fn (from_version: u32, value: std.json.Value) MigrateError!Event;

        /// How a journal is opened. Every field has a default; the defaults are
        /// the durable, forgiving ones.
        pub const Options = struct {
            /// The version stamped into every record `append` writes, and the
            /// version records are expected to be at when read back.
            schema_version: u32 = 1,
            /// Whether this process writes to the journal at all. `.write`
            /// takes the exclusive advisory lock, and a second writer gets
            /// `error.Locked`; `.read` takes no lock, writes nothing, and is
            /// safe to run beside the writer.
            access: Access = .write,
            /// What to do with an unterminated final line. Ignored under
            /// `.read`, which repairs nothing.
            on_truncated: OnTruncated = .drop,
            /// How much of the log `open` reads back before it returns.
            verify: Verify = .quick,
            /// Called for a record written at a version below
            /// `schema_version`. Without it, such a record becomes the `Event`
            /// arm named `unknown` if there is one, and `error.OlderSchema` if
            /// there is not.
            migrate: ?Migrate = null,
            /// How often `append` makes the bytes it wrote durable. The
            /// default is the durable one; README.md states what each level
            /// promises and what it gives up.
            sync: Sync = .always,
            /// How many of the newest records to keep in memory for `records`,
            /// `since` and `waitPast`. Older ones come from the disk. Zero is
            /// allowed: then `replay` and `subscribe` are the ways to read.
            tail_records: usize = 1024,
            /// A second ceiling on the tail, over the records' bytes, for a
            /// journal whose records are large. Whichever bites first wins.
            tail_bytes: usize = 1024 * 1024,
            /// How large a segment may grow before the next `append` starts a
            /// new one. It is also how much of the log `open` reads.
            max_segment_bytes: u64 = 8 * 1024 * 1024,
            /// A second ceiling on a segment, over records. Null is none.
            max_segment_records: ?u64 = null,
            /// How far ahead of the records the active segment is kept
            /// zero-filled, so that an append writes into space the file
            /// already has instead of extending it. Zero, the default,
            /// reserves nothing.
            ///
            /// What it buys is a cheaper durable write: a file whose length
            /// is not changing needs no size written out beside the bytes,
            /// and on the platforms that have the cheaper call this is what
            /// makes it sufficient. What it costs is the zeros — a segment is
            /// written once as zeros and once as records — so it is worth
            /// setting on a journal whose `sync` is `.always` and whose
            /// records are small, and worth leaving alone otherwise.
            preallocate_bytes: u64 = 0,
            /// How many bytes of segment one index entry covers.
            ///
            /// The index is a cache that turns a cursor into a seek. One
            /// entry per record makes the seek exact and costs a sixth of
            /// the log's size in sidecars; one entry per 4096 bytes, the
            /// default, costs a fortieth of that and puts a walk of at most
            /// that many bytes after the seek. Zero is an entry per record.
            ///
            /// It is also what a lookup by time reads, so a larger interval
            /// makes `seqAtOrAfter` read the segment where a smaller one
            /// would have answered from the index alone. Values above
            /// `maxInt(u32)` are refused with `error.IndexIntervalTooLarge`.
            index_interval_bytes: u64 = 4096,
            /// How long a record's line may be.
            ///
            /// `append` refuses a longer one, and a read refuses a segment
            /// with no newline within that many bytes — which is what stops
            /// a damaged segment being taken into memory whole to find out
            /// that it holds no record.
            max_record_bytes: usize = 1024 * 1024,
            /// How large a snapshot file may be to be written or read back. It holds
            /// whatever a fold serialises to, so this is the caller's number
            /// and not the package's; a larger one is
            /// `error.SnapshotTooLarge`.
            max_snapshot_bytes: usize = 64 * 1024 * 1024,
            /// Size of the journal's write buffer. One `append` of a record
            /// larger than this costs an extra write syscall, nothing more.
            write_buffer_size: usize = 64 * 1024,
            /// Size of the buffer a read from the disk streams through.
            read_buffer_size: usize = 64 * 1024,
            /// Whether `append` parses every record back out of the bytes it
            /// is about to write, to prove the `Event` survives the round
            /// trip, and answers `error.NotRoundTrippable` when it does not.
            ///
            /// A journal that keeps a tail or has a sink registered parses
            /// the record back whatever this says, because it needs the
            /// record; this is about the journal that keeps neither, where
            /// the parsed record would be built and dropped unread. That
            /// parse is a third of what an `append` costs.
            verify_round_trip: bool = false,
        };

        /// A snapshot read back from disk.
        ///
        /// `state` is the byte string that was passed to `snapshot`, and `seq`
        /// is the journal's newest sequence number at that moment: fold `state`
        /// into your state and then replay only the records after `seq`, which
        /// is what `subscribeFrom` and `since` take.
        ///
        /// `state` is the caller's, from the allocator `openWithSnapshot` was
        /// given; free it when the fold has been restored from it.
        pub const Snapshot = struct {
            seq: u64,
            state: []const u8,
        };

        /// What `openWithSnapshot` returns: the journal, and the snapshot
        /// beside it if there was one.
        pub const Opened = struct {
            journal: Self,
            snapshot: ?Snapshot,
        };

        /// What reading a record back can go wrong with.
        ///
        /// * `ChecksumMismatch` — a line carries a checksum and does not
        ///   match it: the bytes on the disk are not the bytes that were
        ///   written. This is the one corruption a parse cannot find.
        /// * `CorruptRecord` — a line is not a JSON object with the members
        ///   this format requires, or its `ev` does not parse as `Event`.
        /// * `TruncatedRecord` — a line is unterminated where a complete one
        ///   was required: the final line with `Options.on_truncated` set to
        ///   `.fail`, or any line of a segment that is not the newest.
        /// * `DiscontinuousSeq` — sequence numbers skip or repeat, or the
        ///   records of a segment disagree with the name it is under.
        /// * `BrokenChain` — a record does not link to the one before it.
        ///   Every record carries the checksum of its predecessor, so a
        ///   record spliced in from somewhere else, or a run of them left
        ///   over from an earlier life of the file, is named here rather
        ///   than folded.
        /// * `UnsupportedFormat` — a segment file's first line is not one
        ///   this version writes. The framing carries its version there, so
        ///   a file from another one is refused by name and never read as if
        ///   it were records.
        /// * `NewerSchema` — a record was written at a version above
        ///   `Options.schema_version`. This process is the old one.
        /// * `OlderSchema` — a record was written at a version below
        ///   `Options.schema_version` and there is neither a `migrate` hook nor
        ///   an `unknown` arm to receive it.
        pub const ReadError = Allocator.Error || MigrateError || Log.ScanError ||
            error{ ChecksumMismatch, CorruptRecord, TruncatedRecord, DiscontinuousSeq, BrokenChain, NewerSchema, OlderSchema };

        /// `ReadError`, plus what opening a directory and taking its lock can
        /// go wrong with.
        ///
        /// * `Locked` — another process holds this journal's write lock. It is
        ///   the answer a second writer gets, instead of two writers
        ///   interleaving half-records.
        /// * `ReadOnly` — `Options.access` is `.read` and something would have
        ///   had to be written.
        /// * `IndexIntervalTooLarge` — `Options.index_interval_bytes` cannot
        ///   be represented by the index format's 32-bit interval field.
        pub const OpenError = ReadError || Log.OpenError;

        /// `OpenError`, plus `CorruptSnapshot` for a snapshot file that is not
        /// the object `snapshot` writes. A missing snapshot file is not an
        /// error; it yields `Opened.snapshot == null`.
        pub const OpenWithSnapshotError = OpenError || error{ CorruptSnapshot, SnapshotTooLarge };

        /// Errors from `append`.
        ///
        /// * `PersistenceFailed` — an earlier `append` could not reach the
        ///   disk. Later appends are latched until `reconcile` establishes
        ///   whether the attempted record survived and restores the sequence.
        /// * `NotRoundTrippable` — the event was written to JSON but did not
        ///   parse back as `Event`. Nothing was written to the file.
        /// * `SequenceExhausted` — the newest sequence number is
        ///   `maxInt(i64)`, and one more could not be read back, because a
        ///   sequence number is a JSON integer.
        /// * `RecordTooLarge` — the line the record would be written as is
        ///   longer than `Options.max_record_bytes`. Nothing was written.
        /// * `ReadOnly` — the journal was opened with `Access.read`.
        pub const AppendError = Allocator.Error || Log.AppendError ||
            error{ PersistenceFailed, NotRoundTrippable, SequenceExhausted, RecordTooLarge };

        /// Errors from reconciling the journal after a persistence failure.
        pub const ReconcileError = OpenError;

        /// Errors from `replay`, and from the `Replay` it returns.
        pub const ReplayError = ReadError;

        /// Errors from `seqAtOrAfter`, which may have to rebuild an index
        /// before it can answer and so can fail at everything `open` can.
        pub const SeekError = OpenError;

        /// Errors from `subscribe` and `subscribeFrom`, which replay the
        /// records a cursor has missed before they register the sink.
        pub const SubscribeError = ReplayError || Io.Cancelable;

        /// Errors from `snapshot`.
        pub const SnapshotError = Allocator.Error || Log.SnapshotError || error{SnapshotTooLarge};

        /// Errors from durably closing the active segment.
        pub const CloseError = Log.CloseError;

        /// Errors from `tailer` and from a `Tailer`'s own calls.
        ///
        /// * `InvalidName` — a tailer's name becomes a filename beside the
        ///   log, so it has to be one path component of letters, digits, `-`
        ///   and `_`, and no more than 64 of them.
        /// * `CorruptCursor` — the cursor file is not the object `commit`
        ///   writes. A missing one is not an error; it is a cursor of zero.
        pub const TailerError = Allocator.Error || Io.Cancelable ||
            Log.WriteFileError || error{ InvalidName, CorruptCursor, UnsupportedFormat };

        /// Errors from `compact`. It re-reads the journal it has just written,
        /// so every `OpenError` is possible.
        pub const CompactError = OpenError || Log.CompactError || error{PersistenceFailed};

        /// Errors from `dropSegmentsBefore`.
        pub const DropError = Log.CompactError;

        /// Errors from `backup`.
        ///
        /// * `BackupInPlace` — the destination is the journal's own directory,
        ///   which would have meant copying its segments over themselves.
        pub const BackupError = OpenError || Log.BackupError;

        /// Errors from `truncateAfter`.
        ///
        /// * `SeqTooOld` — the log no longer holds a record at or before the
        ///   cut, so truncating to it would claim a history that has already
        ///   been dropped.
        pub const TruncateError = CompactError || Log.TruncateError;

        /// The line, as written, except for the checksum `append` appends to
        /// it. Field order here is the field order on disk.
        const Line = struct {
            seq: u64,
            at: i64,
            v: u32,
            /// The checksum of the record before this one, or the segment
            /// header's `root` for the first record in a file.
            p: u32,
            ev: Event,
        };

        const UnknownArm = enum { empty, json_value };

        /// Whether `Event` has an arm this package can put an unrecognised
        /// older record into, and what shape it is.
        const unknown_arm: ?UnknownArm = blk: {
            const info = @typeInfo(Event);
            if (info != .@"union") break :blk null;
            for (info.@"union".fields) |field| {
                if (!std.mem.eql(u8, field.name, "unknown")) continue;
                if (field.type == void) break :blk .empty;
                if (field.type == std.json.Value) break :blk .json_value;
                break :blk null;
            }
            break :blk null;
        };

        //====================================================================
        // Opening.
        //====================================================================

        /// Open the journal directory at `path`, creating it if it is not
        /// there, and read back the newest records.
        ///
        /// The sequence number continues from the last record, so a restart
        /// never reuses a number. A final line the previous writer did not
        /// finish is handled per `Options.on_truncated`; with the default it is
        /// dropped, the segment is shortened to the last complete record, and
        /// the byte count lands in `dropped_bytes`, so the next `append` writes
        /// a well-formed line.
        ///
        /// What this reads is the newest segment — bounded by
        /// `Options.max_segment_bytes` — plus one line of each older segment,
        /// and it parses only the records that fit in the tail. A record older
        /// than that is checked when something reads it. Memory is the tail
        /// plus the largest record, not the log.
        ///
        /// `path` may be relative to the current directory or absolute. Release
        /// with `deinit`.
        pub fn open(gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!Self {
            var log = try Log.open(gpa, io, path, .{
                .access = options.access,
                .on_truncated = options.on_truncated,
                .sync = options.sync,
                .write_buffer_size = options.write_buffer_size,
                .read_buffer_size = options.read_buffer_size,
                .max_segment_bytes = options.max_segment_bytes,
                .max_segment_records = options.max_segment_records,
                .preallocate_bytes = options.preallocate_bytes,
                .index_interval_bytes = options.index_interval_bytes,
                .max_record_bytes = options.max_record_bytes,
            });
            errdefer log.deinit(io);

            var self: Self = .{
                .gpa = gpa,
                .log = log,
                .options = options,
                .tail = .empty,
                .tail_arenas = .empty,
                .tail_bytes = 0,
                .scratch = .init(gpa),
                .sinks = .empty,
                .mutex = .init,
                .changed = .init,
                .nudges = 0,
                .seq = 0,
                .persistence_failed = false,
                .dropped_bytes = log.dropped_bytes,
            };
            errdefer {
                self.clearTail();
                self.tail.deinit(gpa);
                self.tail_arenas.deinit(gpa);
                self.scratch.deinit();
            }
            try self.fillTail(io);
            if (options.verify == .full) _ = try self.verify(io);
            return self;
        }

        /// `open`, plus the snapshot written beside the journal by a previous
        /// `snapshot` call, if there is one.
        ///
        /// A caller that restores `Opened.snapshot.?.state` into its fold then
        /// needs only the records after `Opened.snapshot.?.seq`; hand that
        /// number to `subscribeFrom`. The state is the caller's to free.
        pub fn openWithSnapshot(
            gpa: Allocator,
            io: Io,
            path: []const u8,
            options: Options,
        ) OpenWithSnapshotError!Opened {
            var self = try open(gpa, io, path, options);
            errdefer self.deinit(io);
            // Read before the journal is copied into the result: a field
            // initializer that mutated `self` after `.journal = self` would
            // leave the bookkeeping behind in the original.
            const found = try self.readSnapshot(io);
            return .{ .journal = self, .snapshot = found };
        }

        /// Flush and durably close the active segment, then release the lock
        /// and every allocation. The journal is consumed even when an error
        /// is returned, and every slice it handed out is invalid afterwards.
        pub fn close(self: *Self, io: Io) CloseError!void {
            defer self.release();
            try self.log.close(io);
        }

        /// Best-effort fallback for scopes that cannot return a close error.
        /// Prefer `close` when `.on_segment` relies on shutdown for its final
        /// durable write. Every slice the journal handed out is invalid.
        pub fn deinit(self: *Self, io: Io) void {
            self.log.deinit(io);
            self.release();
        }

        fn release(self: *Self) void {
            self.clearTail();
            self.tail.deinit(self.gpa);
            self.tail_arenas.deinit(self.gpa);
            self.sinks.deinit(self.gpa);
            self.scratch.deinit();
            self.* = undefined;
        }

        //====================================================================
        // Writing.
        //====================================================================

        /// Serialise `event`, write it, make it durable, publish it.
        ///
        /// Returns the new record's sequence number. `at` is stored as given;
        /// chronicle never reads a clock.
        ///
        /// A record the journal keeps — for the tail, or for a sink — is
        /// parsed back out of the bytes that were written, so it owns its own
        /// memory and is exactly what a reopen would produce: an `Event` whose
        /// slices point at a stack buffer is safe to append. A journal that
        /// keeps neither does not build that record at all; see
        /// `Options.verify_round_trip`.
        ///
        /// Nothing is published to memory unless the durability operation
        /// succeeds. If a write, flush or `fsync` fails, no sink is called and
        /// later appends return `error.PersistenceFailed`. A complete record
        /// may nevertheless have reached the file before the failure was
        /// reported; `reconcile` reads the authoritative result back.
        ///
        /// Safe to call from any task or thread.
        pub fn append(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A journal opened for reading is refused before anything else: it
            // is not a journal that has failed, and it must not be latched as
            // one.
            if (self.options.access == .read) return error.ReadOnly;
            if (self.persistence_failed) return error.PersistenceFailed;
            if (self.seq >= std.math.maxInt(i64)) return error.SequenceExhausted;

            const next = self.seq + 1;
            // Built before the write: a record the journal could not hold is a
            // record that must not reach the disk either.
            var built = try self.encode(next, at, self.log.chainTip(), event);
            var held = false;
            defer if (!held) built.release(self.gpa);

            // Reserve before writing: after the bytes are durable nothing may
            // fail, or the disk would hold a record memory does not.
            try self.tail.ensureUnusedCapacity(self.gpa, 1);
            try self.tail_arenas.ensureUnusedCapacity(self.gpa, 1);

            {
                errdefer self.persistence_failed = true;
                try self.log.appendLine(io, built.bytes, built.at, built.checksum);
            }

            held = self.publish(built);
            self.changed.broadcast(io);
            // Last, so that a sink reading this record was reading memory that
            // still existed.
            self.trimTail();
            return next;
        }

        /// Write every entry, in order, under one `fsync`, and return the
        /// sequence number of the last one.
        ///
        /// This is group commit and not a transaction. The records go into the
        /// log one line each, exactly as `append` writes them, and the whole
        /// batch is made durable once at the end instead of once per record —
        /// so a batch of a thousand costs one `fsync` under
        /// `Options.sync = .always` rather than a thousand. What it does not
        /// buy is atomicity: a crash inside the batch leaves a **prefix** of
        /// it on the disk, with a torn final line at worst, which is the same
        /// shape a crash inside a single `append` leaves and is repaired the
        /// same way. If the batch must be all-or-nothing to your fold, say so
        /// in the records — a record that opens the group and one that closes
        /// it — because the log will not say it for you.
        ///
        /// Nothing is published unless the bytes reached the disk: no record
        /// is added to the tail and no sink is called until the `fsync`
        /// returns. A failure part-way through latches the journal exactly as
        /// `append`'s does, and the disk may then hold some of the batch;
        /// `reconcile` or reopening reads back what survived.
        ///
        /// Each record is serialised as it is written rather than the batch
        /// being formed first, so memory holds the batch only as far as the
        /// tail and the sinks need it: a journal with neither holds one line
        /// at a time however long the batch is. A record the journal cannot
        /// form — one longer than `Options.max_record_bytes`, or an `Event`
        /// that does not survive the round trip when that is checked — takes
        /// back the lines of the batch already staged, so a refused batch
        /// leaves the log exactly as it was.
        ///
        /// An empty slice writes nothing and returns `lastSeq`.
        ///
        /// Safe to call from any task or thread.
        pub fn appendAll(self: *Self, io: Io, entries: []const Entry) AppendError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.options.access == .read) return error.ReadOnly;
            if (self.persistence_failed) return error.PersistenceFailed;
            if (entries.len == 0) return self.seq;
            if (entries.len > std.math.maxInt(i64) - self.seq) return error.SequenceExhausted;

            // Reserved before anything is written: after the bytes are
            // durable nothing may fail, or the disk would hold records
            // memory does not.
            try self.tail.ensureUnusedCapacity(self.gpa, entries.len);
            try self.tail_arenas.ensureUnusedCapacity(self.gpa, entries.len);

            // Only the records something will read are kept: a journal with
            // no tail and no sink holds one line at a time, however long the
            // batch is.
            var built: std.ArrayList(Built) = .empty;
            defer built.deinit(self.gpa);
            var published = false;
            defer if (!published) for (built.items) |*item| item.release(self.gpa);
            if (self.needsRecord()) try built.ensureTotalCapacityPrecise(self.gpa, entries.len);

            const before = self.seq;
            var link = self.log.chainTip();
            for (entries, 0..) |entry, i| {
                var item = self.encode(self.seq + i + 1, entry.at, link, entry.event) catch |err| {
                    self.unstage(io, before);
                    return err;
                };
                link = item.checksum;
                {
                    errdefer self.persistence_failed = true;
                    self.log.stageLine(io, item.bytes, item.at, item.checksum) catch |err| {
                        item.release(self.gpa);
                        return err;
                    };
                }
                if (item.record != null) built.appendAssumeCapacity(item) else item.release(self.gpa);
            }

            {
                errdefer self.persistence_failed = true;
                try self.log.commit(io);
            }
            published = true;

            for (built.items) |*item| {
                _ = self.publish(item.*);
            }
            // A batch of records nothing keeps still moved the sequence.
            self.seq = before + entries.len;
            self.changed.broadcast(io);
            self.trimTail();
            return self.seq;
        }

        /// Re-read the journal after an append persistence failure and report
        /// the newest sequence number that actually survived.
        ///
        /// A failed flush or `fsync` cannot say whether the operating system
        /// accepted the complete line before reporting the error. Until this
        /// call succeeds, appends stay latched with `error.PersistenceFailed`.
        /// On success the tail is rebuilt, the latch is cleared, and the
        /// caller can compare the returned sequence with the attempted one
        /// before deciding whether to retry it.
        pub fn reconcile(self: *Self, io: Io) ReconcileError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.options.access == .read) return error.ReadOnly;
            if (!self.persistence_failed) return self.seq;

            try self.log.reload(io);
            self.clearTail();
            try self.fillTail(io);
            self.dropped_bytes = self.log.dropped_bytes;
            self.persistence_failed = false;
            return self.seq;
        }

        /// Take back the lines of a batch that was staged and never
        /// committed, so that a batch which could not be formed leaves the
        /// log exactly as it was.
        ///
        /// It is the same shortening `truncateAfter` does, for the same
        /// reason: what is on the disk has to end at a record boundary
        /// whatever happened. Nothing here was ever acknowledged, so nothing
        /// is lost by it.
        fn unstage(self: *Self, io: Io, seq: u64) void {
            if (self.seq <= seq and self.log.lastSeq() <= seq) return;
            self.putBack(io, seq) catch {
                // The log could not be put back. What is on the disk is
                // still whole records in order, and a reopen reads them, but
                // this process must not hand any of them out as appended.
                self.persistence_failed = true;
            };
        }

        fn putBack(self: *Self, io: Io, seq: u64) TruncateError!void {
            try self.log.truncateAfter(io, seq);
            self.clearTail();
            try self.fillTail(io);
        }

        /// Wake every `waitPast` with no new record — a shutdown, or something
        /// that moved beside the log.
        ///
        /// A nudge reaches the readers that are waiting when it happens and is
        /// not remembered for one that arrives afterwards, so a shutdown that
        /// must reach every reader sets its own flag first and nudges until the
        /// readers are gone.
        ///
        /// Safe to call from any task or thread.
        pub fn nudge(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.nudges +%= 1;
            self.changed.broadcast(io);
        }

        //====================================================================
        // Reading.
        //====================================================================

        /// The records the tail holds, oldest first — `since(0)`, named.
        ///
        /// A journal that has been running for a year holds a bounded tail and
        /// not its history, so this is a window and says so: read
        /// `Window.complete` before treating it as everything.
        ///
        /// Call it from the task that appends, or under coordination of your
        /// own; `waitPast` is the equivalent that takes the journal's lock.
        pub fn records(self: *const Self) Window {
            return self.since(0);
        }

        /// The records after `cursor` that are in the tail.
        ///
        /// A cursor is where a reader got to, so a cursor at the newest
        /// sequence number yields nothing. A cursor older than the tail yields
        /// the whole tail with `Window.complete` false: the records in between
        /// are on the disk, and `replay` or `subscribeFrom` is how to get them.
        ///
        /// Same validity and same threading rule as `records`.
        pub fn since(self: *const Self, cursor: u64) Window {
            const items = self.tail.items;
            if (items.len == 0) return .{ .records = items, .complete = cursor >= self.seq };
            const tail_base = items[0].seq - 1;
            if (cursor < tail_base) return .{ .records = items, .complete = false };
            const skip: usize = @intCast(@min(cursor - tail_base, items.len));
            return .{ .records = items[skip..], .complete = true };
        }

        /// Block until there is a record after `cursor`, or until `nudge`, then
        /// return `since(cursor)`.
        ///
        /// The window is taken under the lock, so it does not grow under the
        /// reader — but a later `append` can still evict it, so handle it
        /// before waiting again. A reader that waits again passes the sequence
        /// number of the last record it handled.
        ///
        /// Safe to call from any task or thread, including several at once.
        pub fn waitPast(self: *Self, io: Io, cursor: u64) Io.Cancelable!Window {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const nudged = self.nudges;
            while (self.seq <= cursor and self.nudges == nudged) try self.changed.wait(io, &self.mutex);
            return self.since(cursor);
        }

        /// What a walk keeps between records so that the records it hands on
        /// are a run: where the reader had got to, what the next sequence
        /// number must be, and what the next record must link back to.
        ///
        /// A seek lands at a record at or before the cursor, because a
        /// segment — and, with one index entry per interval, a run of records
        /// — is the unit it lands in. So the first records a walk reads may
        /// be ones the reader already has: those are stepped over, and their
        /// checksums are still taken into the chain, so the first record
        /// handed on is checked against the one in front of it.
        const Continuity = struct {
            cursor: u64,
            expected: ?u64 = null,
            link: ?u32 = null,

            fn beginSegment(walk: *Continuity, boundary: Log.Scan.Boundary) ReadError!void {
                if (walk.expected) |want| {
                    if (boundary.base_seq != want) return error.DiscontinuousSeq;
                }
                if (walk.link) |previous| {
                    if (boundary.root != previous) return error.BrokenChain;
                }
                walk.expected = boundary.base_seq;
                walk.link = boundary.root;
            }

            /// Whether this record is one to hand on. False means it is at or
            /// behind the cursor and has been stepped over.
            fn accept(walk: *Continuity, header: Header) ReadError!bool {
                if (walk.expected) |want| {
                    if (header.seq != want) return error.DiscontinuousSeq;
                }
                if (walk.link) |previous| {
                    if (header.p != previous) return error.BrokenChain;
                }
                walk.expected = header.seq + 1;
                walk.link = header.c;
                return header.seq > walk.cursor;
            }
        };

        /// What `replay` returns: a walk over the log from the disk.
        pub const Replay = struct {
            journal: *Self,
            scan: Log.Scan,
            /// Holds the record `next` last returned, and nothing else.
            arena: std.heap.ArenaAllocator,
            /// Its own, so that two walks and an `append` never share one.
            scratch: std.heap.ArenaAllocator,
            run: Continuity,

            pub fn deinit(walk: *Replay, io: Io) void {
                walk.scan.deinit(io);
                walk.arena.deinit();
                walk.scratch.deinit();
                walk.* = undefined;
            }

            /// The next record, or null at the end of the log. It is valid
            /// until the next call to `next` or to `deinit`.
            pub fn next(walk: *Replay, io: Io) ReplayError!?Record {
                while (try walk.scan.next(io)) |line| {
                    if (walk.scan.takeBoundary()) |boundary| try walk.run.beginSegment(boundary);
                    _ = walk.scratch.reset(.retain_capacity);
                    const header = try parseHeader(walk.scratch.allocator(), line);
                    // Stepping over a record before its event is parsed is
                    // what lets a reader hold a cursor into a log whose
                    // events it does not know.
                    if (!try walk.run.accept(header)) continue;
                    _ = walk.arena.reset(.retain_capacity);
                    return try walk.journal.recordFrom(walk.arena.allocator(), header, line);
                }
                return null;
            }
        };

        /// A walk over every record after `cursor`, read from the disk.
        ///
        /// This is how a fold covers a history longer than memory: it holds one
        /// record and one read buffer at a time, however many segments it
        /// crosses. Release it with `deinit`.
        ///
        /// It reads the segments as they were when it was made. A `compact` or
        /// a `dropSegmentsBefore` beside it may leave it reading a file that
        /// has gone, which it reports as an error rather than as wrong records.
        ///
        /// Records appended while it runs may or may not appear: a `Replay`
        /// does not hold the journal's lock. `subscribeFrom` is the version
        /// that misses nothing.
        ///
        /// It writes nothing. A segment whose index is missing or stale is
        /// walked from its start rather than indexed on the way, because
        /// building an index beside an `append` that is writing one is not
        /// something a call that takes no lock may do. `open`, `refresh` and
        /// `seqAtOrAfter` hold the lock and are what build indexes.
        pub fn replay(self: *Self, io: Io, cursor: u64) ReplayError!Replay {
            return self.replayFrom(io, cursor, false);
        }

        /// `replay`, saying whether the walk may build an index it finds
        /// missing. Only a caller holding the journal's lock may say yes.
        fn replayFrom(self: *Self, io: Io, cursor: u64, may_write: bool) ReplayError!Replay {
            return .{
                .journal = self,
                .scan = try self.log.scanFrom(io, cursor, may_write),
                .arena = .init(self.gpa),
                .scratch = .init(self.gpa),
                .run = .{ .cursor = cursor },
            };
        }

        /// Read every record of every segment back, through the checks a
        /// replay makes — the checksum, the envelope, the schema version and
        /// the sequence — and report how many there were.
        ///
        /// This is what `Options.verify = .full` runs at `open`, and it is
        /// what a caller runs on a journal it has reason to doubt. It costs
        /// the log rather than one segment.
        pub fn verify(self: *Self, io: Io) ReplayError!u64 {
            var walk = try self.replay(io, self.log.baseSeq());
            defer walk.deinit(io);
            var seen: u64 = 0;
            while (try walk.next(io)) |_| seen += 1;
            return seen;
        }

        /// The newest sequence number, or zero on an empty journal.
        ///
        /// Safe to call from any task or thread.
        pub fn lastSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.seq;
        }

        /// The lowest sequence number whose record's timestamp is at or after
        /// `at`, or null when no record in the log has one.
        ///
        /// `at` is compared against the `at` each record was appended with —
        /// chronicle never reads a clock, so this is a search over the numbers
        /// you stored, in whatever unit you stored them in.
        ///
        /// The timestamps are not assumed to rise with the sequence numbers,
        /// because nothing makes a caller pass them in order. So the index
        /// carries each record's `at` beside its offset and its header carries
        /// the lowest and the highest in the segment: a segment whose highest
        /// is below `at` cannot hold a record that qualifies and is skipped
        /// without its file being opened, and one that is not skipped is
        /// answered from its index. The active segment's index is not sealed
        /// yet, so that one is walked — bounded by
        /// `Options.max_segment_bytes`, and only when its own timestamps say a
        /// record could be in there.
        ///
        /// An index that is missing, stale or from an older format is rebuilt
        /// on the way, as every other read does; a journal opened with
        /// `Options.access = .read` cannot write one and walks the segment
        /// instead. A record carrying no readable `at` is
        /// `error.CorruptRecord`, because a lookup by time cannot step over a
        /// record that has no time.
        ///
        /// Safe to call from any task or thread.
        pub fn seqAtOrAfter(self: *Self, io: Io, at: i64) SeekError!?u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.log.seqAtOrAfter(io, at);
        }

        /// Read the directory again: pick up segments another process has
        /// added, and rebuild the tail from what is there now.
        ///
        /// This is how a `.read` journal tails a writer in another process. A
        /// `Replay` already reads to the end of every segment it knows about,
        /// so this is what a reader needs when the writer has *rotated*. It
        /// costs a walk of the newest segment, as `open` does.
        ///
        /// Safe to call from any task or thread.
        pub fn refresh(self: *Self, io: Io) OpenError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try self.log.reload(io);
            self.clearTail();
            try self.fillTail(io);
        }

        /// How many segments the log is spread over. One for a young journal;
        /// it grows by one every `Options.max_segment_bytes`.
        pub fn segmentCount(self: *const Self) usize {
            return self.log.segments.items.len;
        }

        /// The oldest sequence number the log still holds — 1 until a `compact`
        /// or a `dropSegmentsBefore` drops a prefix, and one past `lastSeq` on
        /// a log with no records in it. Compare it against a cursor to see what
        /// a reader has missed for good.
        pub fn oldestSeq(self: *const Self) u64 {
            return self.log.baseSeq() + 1;
        }

        /// What the log is made of, in numbers.
        pub const Stats = struct {
            /// How many segment files it is spread over.
            segments: usize,
            /// How many records they hold.
            records: u64,
            /// The bytes of those records, over every segment. The line at
            /// the head of each segment file is not counted, and neither are
            /// the index sidecars, the lock and the snapshot: those are the
            /// framing, a cache and a copy of a fold, not the log.
            bytes: u64,
            /// The oldest sequence number still held and the newest. Both are
            /// zero on a log with no records in it.
            oldest_seq: u64,
            newest_seq: u64,
        };

        /// `Stats`, read off the segments the journal already knows about: no
        /// file is opened and nothing is scanned.
        ///
        /// Safe to call from any task or thread.
        pub fn stats(self: *Self, io: Io) Io.Cancelable!Stats {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            var bytes: u64 = 0;
            for (self.log.segments.items) |segment| bytes += segment.bytes - segment.header_bytes;
            const oldest = self.log.baseSeq() + 1;
            const empty = self.seq == 0 or oldest > self.seq;
            return .{
                .segments = self.log.segments.items.len,
                .records = self.seq + 1 -| oldest,
                .bytes = bytes,
                .oldest_seq = if (empty) 0 else oldest,
                .newest_seq = self.seq,
            };
        }

        /// Register a fold and hand it every record the journal holds, then
        /// every record appended afterwards.
        ///
        /// A fold built this way is built the same way whether the records came
        /// off the disk or arrived live, which is the point.
        ///
        /// The sink is called with the journal's lock held, and lives until
        /// `unsubscribe` or `deinit`.
        pub fn subscribe(self: *Self, io: Io, sink: Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, 0);
        }

        /// `subscribe`, starting after `cursor` — the sequence number of a
        /// snapshot the fold has already been restored from.
        ///
        /// Records the tail no longer holds are streamed from the disk one at a
        /// time, so a fold over a year of records costs the largest record and
        /// not the year. The journal's lock is held for the whole replay: an
        /// `append` from another task waits for it, which is what makes the
        /// hand-over from the disk to the live records seamless.
        pub fn subscribeFrom(self: *Self, io: Io, sink: Sink, cursor: u64) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, cursor);
        }

        /// `subscribe` for several folds at once, over one pass of the log.
        pub fn subscribeAll(self: *Self, io: Io, sinks: []const Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, sinks, 0);
        }

        /// Register every fold in `sinks` and hand each of them every record
        /// after `cursor`, reading the disk once for all of them.
        ///
        /// Subscribing five folds one at a time reads the log five times: each
        /// call opens its own walk, verifies every checksum again and parses
        /// every event again. This does that work once and calls each sink per
        /// record, which costs the same as one subscriber — the callbacks are
        /// free beside the decode.
        ///
        /// It is one call under one lock, so it is also the way to start
        /// several folds at the same record: a record appended beside it lands
        /// in all of them or in none of them, never in some.
        ///
        /// The sinks are registered in the order given and are called in that
        /// order for every record afterwards.
        pub fn subscribeAllFrom(self: *Self, io: Io, sinks: []const Sink, cursor: u64) SubscribeError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const before = self.sinks.items.len;
            try self.sinks.appendSlice(self.gpa, sinks);
            errdefer self.sinks.shrinkRetainingCapacity(before);
            // The registered copies, not the caller's slice: a sink that is
            // handed records here must be the same sink the next `append`
            // finds, whatever the caller does with its own array.
            const registered = self.sinks.items[before..];

            var delivered = cursor;
            if (!self.since(cursor).complete) {
                var walk = try self.replayFrom(io, cursor, true);
                defer walk.deinit(io);
                while (try walk.next(io)) |record| {
                    for (registered) |sink| sink.f(sink.ctx, record);
                    delivered = record.seq;
                }
            }
            for (self.since(delivered).records) |record| {
                for (registered) |sink| sink.f(sink.ctx, record);
            }
        }

        /// Drop a fold registered by `subscribe`, `subscribeFrom`,
        /// `subscribeAll` or `subscribeAllFrom`, and report whether one went.
        ///
        /// A sink is identified by the pair of pointers it is made of, so the
        /// argument is the same `Sink` that was registered. Registering the
        /// same pair twice takes two calls to remove. The remaining folds keep
        /// the order they were registered in.
        ///
        /// This is what a reconnecting client's fold needs: it is added when
        /// the client arrives and dropped when it goes, rather than living
        /// until the journal closes.
        ///
        /// Safe to call from any task or thread.
        pub fn unsubscribe(self: *Self, io: Io, sink: Sink) Io.Cancelable!bool {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            for (self.sinks.items, 0..) |registered, i| {
                if (registered.ctx != sink.ctx or registered.f != sink.f) continue;
                _ = self.sinks.orderedRemove(i);
                return true;
            }
            return false;
        }

        /// A named reader and the cursor it has committed.
        ///
        /// A cursor is a `u64` — the sequence number a reader has finished
        /// with — and this is that number with a name and somewhere to live:
        /// `<path>/<name>.cursor`, replaced whole the way a snapshot is, so a
        /// reader that restarts picks up where it left off without the program
        /// around it having to keep the number anywhere.
        ///
        /// **A tailer writes nothing to the log.** Its cursor file is the one
        /// file a journal opened with `Options.access = .read` creates, and it
        /// creates no other: no repair, no index, no compaction, no record. So
        /// any number of readers, under any number of names, in any number of
        /// processes, beside a live writer.
        ///
        /// Nothing advances the cursor for you. `replay` reads from where it
        /// is, and `commit` is what moves it — after the records have been
        /// handled, so that a crash in between replays them again rather than
        /// losing them. It may move backwards, which is how a reader is asked
        /// to do a stretch of history over.
        pub const Tailer = struct {
            journal: *Self,
            /// This reader's name, owned by the tailer.
            name: []const u8,
            /// Where it has got to. Zero for a name that has never committed
            /// one, and left where it was by a `compact` that dropped past
            /// it — compare it against `oldestSeq` to see what has gone.
            cursor: u64,

            /// Release the name. The cursor file stays on the disk; that is
            /// the point of it.
            pub fn deinit(tail: *Tailer) void {
                tail.journal.gpa.free(tail.name);
                tail.* = undefined;
            }

            /// A walk over every record after the committed cursor, read from
            /// the disk. `Journal.replay(io, tailer.cursor)`, named.
            pub fn replay(tail: *Tailer, io: Io) ReplayError!Replay {
                return tail.journal.replay(io, tail.cursor);
            }

            /// Record `seq` as where this reader has got to, durably, and move
            /// `cursor` to it.
            ///
            /// The file is written beside the log and renamed into place, so a
            /// crash leaves either the whole old cursor or the whole new one —
            /// never a number that was never reached.
            ///
            /// Safe to call from any task or thread.
            pub fn commit(tail: *Tailer, io: Io, seq: u64) TailerError!void {
                const self = tail.journal;
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                const document = try std.json.Stringify.valueAlloc(
                    self.gpa,
                    .{ .fmt = document_format, .seq = seq },
                    .{},
                );
                defer self.gpa.free(document);

                const file = try cursorName(self.gpa, tail.name);
                defer self.gpa.free(file);
                try self.log.writeAtomic(io, file, document);
                tail.cursor = seq;
            }

            /// Remove this reader's cursor file, so that the next `tailer`
            /// under this name starts from zero. The tailer itself is left at
            /// the cursor it had; `deinit` is still how it ends.
            ///
            /// Safe to call from any task or thread.
            pub fn forget(tail: *Tailer, io: Io) TailerError!void {
                const self = tail.journal;
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                const file = try cursorName(self.gpa, tail.name);
                defer self.gpa.free(file);
                self.log.dir.deleteFile(io, file) catch |err| switch (err) {
                    error.FileNotFound => return,
                    error.Canceled => return error.Canceled,
                    else => |e| return e,
                };
                try self.log.syncDir(io);
            }
        };

        /// A named reader and where it has got to, as the directory holds
        /// it: the pair `readers` lists, without opening a `Tailer`.
        pub const Reader = struct {
            /// Owned by the `Readers` it came in.
            name: []const u8,
            cursor: u64,
        };

        /// What `readers` returns. Release it with `deinit`.
        pub const Readers = struct {
            items: []const Reader,
            gpa: Allocator,

            pub fn deinit(list: *Readers) void {
                for (list.items) |reader| list.gpa.free(reader.name);
                list.gpa.free(list.items);
                list.* = undefined;
            }
        };

        /// Every named reader that has committed a cursor beside this log,
        /// and the number each of them last committed.
        ///
        /// A cursor file is written by whoever holds the name, in whatever
        /// process; this reads the directory rather than any register this
        /// journal keeps, so a reader in another process is in the list.
        ///
        /// Safe to call from any task or thread.
        pub fn readers(self: *Self, io: Io) TailerError!Readers {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var found: std.ArrayList(Reader) = .empty;
            errdefer {
                for (found.items) |reader| self.gpa.free(reader.name);
                found.deinit(self.gpa);
            }

            var iterator = self.log.dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind == .directory) continue;
                if (!std.mem.endsWith(u8, entry.name, cursor_extension)) continue;
                const name = entry.name[0 .. entry.name.len - cursor_extension.len];
                if (!validTailerName(name)) continue;
                const owned = try self.gpa.dupe(u8, name);
                errdefer self.gpa.free(owned);
                try found.append(self.gpa, .{
                    .name = owned,
                    .cursor = try self.readCursor(io, owned),
                });
            }
            return .{ .items = try found.toOwnedSlice(self.gpa), .gpa = self.gpa };
        }

        /// The lowest cursor any named reader has committed, or null when no
        /// reader has committed one.
        ///
        /// This is what retention is for: every record at or below it has
        /// been handled by every reader that keeps a cursor, so
        /// `dropSegmentsBefore(minCursor)` drops only what they are all past.
        /// A reader that keeps no cursor is not in the answer, because
        /// nothing beside the log says it exists.
        ///
        /// Safe to call from any task or thread.
        pub fn minCursor(self: *Self, io: Io) TailerError!?u64 {
            var list = try self.readers(io);
            defer list.deinit();
            var lowest: ?u64 = null;
            for (list.items) |reader| {
                lowest = if (lowest) |value| @min(value, reader.cursor) else reader.cursor;
            }
            return lowest;
        }

        /// Open the named reader `name`, reading back the cursor it last
        /// committed — zero if it has never committed one.
        ///
        /// The name becomes a filename beside the log, so it is one path
        /// component of letters, digits, `-` and `_`; anything else is
        /// `error.InvalidName`. Release the handle with `Tailer.deinit`, which
        /// leaves the cursor file where it is.
        ///
        /// Safe to call from any task or thread.
        pub fn tailer(self: *Self, io: Io, name: []const u8) TailerError!Tailer {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (!validTailerName(name)) return error.InvalidName;
            const owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned);
            return .{ .journal = self, .name = owned, .cursor = try self.readCursor(io, owned) };
        }

        /// One path component of letters, digits, `-` and `_`: the characters
        /// every filesystem this package runs on agrees about, and none of the
        /// ones — a separator, a dot, a colon — that would let a name reach out
        /// of the journal's directory or name a file already in it.
        fn validTailerName(name: []const u8) bool {
            if (name.len == 0 or name.len > 64) return false;
            for (name) |byte| switch (byte) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                else => return false,
            };
            return true;
        }

        fn cursorName(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
            return std.mem.concat(gpa, u8, &.{ name, cursor_extension });
        }

        /// Read one of the two documents beside the log — the snapshot or a
        /// cursor — into `arena`, bounded, and check the version it says it
        /// is in. Null when there is no such file, which is not an error for
        /// either of them.
        ///
        /// `Malformed` is what a file that is not the document becomes, so
        /// that the two callers keep their own names for it.
        fn readDocument(
            self: *Self,
            io: Io,
            arena: Allocator,
            Document: type,
            name: []const u8,
            limit: usize,
            Malformed: anyerror,
        ) (Allocator.Error || Io.Cancelable || anyerror)!?Document {
            const bytes = self.log.dir.readFileAlloc(
                io,
                name,
                arena,
                .limited(limit),
            ) catch |err| switch (err) {
                error.FileNotFound => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return Malformed,
            };
            const Versioned = struct { fmt: u32 };
            const version = std.json.parseFromSliceLeaky(
                Versioned,
                arena,
                bytes,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return Malformed,
            };
            if (version.fmt != document_format) return error.UnsupportedFormat;
            return std.json.parseFromSliceLeaky(
                Document,
                arena,
                bytes,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return Malformed,
            };
        }

        fn readCursor(self: *Self, io: Io, name: []const u8) TailerError!u64 {
            const file = try cursorName(self.gpa, name);
            defer self.gpa.free(file);

            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const Document = struct { seq: u64 };
            // A cursor is a number with a name on it. Nothing this package
            // writes there is longer than this, so nothing longer is read.
            const document = self.readDocument(
                io,
                arena.allocator(),
                Document,
                file,
                4096,
                error.CorruptCursor,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.UnsupportedFormat => return error.UnsupportedFormat,
                else => return error.CorruptCursor,
            } orelse return 0;
            return document.seq;
        }

        //====================================================================
        // Snapshots and retention.
        //====================================================================

        /// Write `state_bytes` and the current sequence number to
        /// `<path>/snapshot`, replacing any snapshot there.
        ///
        /// `state_bytes` is opaque to chronicle: whatever your fold serialises
        /// to. It is stored base64-encoded in a JSON object, so the snapshot
        /// file is text however binary the state is.
        /// A document larger than `Options.max_snapshot_bytes` is refused
        /// with `error.SnapshotTooLarge` before it replaces the old snapshot.
        ///
        /// The replacement is written to a neighbouring temporary file, flushed
        /// and `fsync`ed, and then renamed over the destination, so a reader
        /// never sees a half-written snapshot. A snapshot is only ever an
        /// optimisation: deleting it costs replay time and nothing else.
        ///
        /// Safe to call from any task or thread.
        pub fn snapshot(self: *Self, io: Io, state_bytes: []const u8) SnapshotError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const encoder = std.base64.standard.Encoder;
            const encoded_size = encoder.calcSize(state_bytes.len);
            const framing_size = std.fmt.count(
                "{{\"fmt\":{d},\"seq\":{d},\"state\":\"\"}}",
                .{ document_format, self.seq },
            );
            if (encoded_size > self.options.max_snapshot_bytes or
                framing_size > self.options.max_snapshot_bytes - encoded_size)
            {
                return error.SnapshotTooLarge;
            }
            const b64 = try self.gpa.alloc(u8, encoded_size);
            defer self.gpa.free(b64);
            _ = encoder.encode(b64, state_bytes);

            const document = try std.json.Stringify.valueAlloc(
                self.gpa,
                .{ .fmt = document_format, .seq = self.seq, .state = b64 },
                .{},
            );
            defer self.gpa.free(document);

            try self.log.syncBeforeSnapshot(io);
            try self.log.writeSnapshot(io, document);
        }

        /// Delete every whole segment whose records are all at or before `seq`,
        /// and report how many went.
        ///
        /// This is the cheap half of retention: one `unlink` per segment, no
        /// file rewritten, the newest segment never touched. Call it after a
        /// `snapshot` that covers `seq`. Nothing calls it for you — history
        /// goes when you say so and not before.
        ///
        /// The records that survive keep their sequence numbers. A cursor from
        /// before the cut yields what is left, and `Window.complete` is how a
        /// reader notices.
        ///
        /// Safe to call from any task or thread.
        pub fn dropSegmentsBefore(self: *Self, io: Io, seq: u64) DropError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const dropped = try self.log.dropSegmentsBefore(io, seq);
            if (dropped != 0) self.dropTailBefore(self.log.baseSeq() + 1);
            return dropped;
        }

        /// Drop every record after `seq`, so that `lastSeq` becomes `seq` and
        /// the next `append` writes `seq + 1`.
        ///
        /// This is the one call that moves the sequence backwards, and the
        /// numbers it frees are handed out again — so a reader holding a
        /// cursor past `seq` is holding a cursor into a history that no longer
        /// exists, and has to be told. It is for rolling back records a crash
        /// left half-meant, not for retention: `compact` and
        /// `dropSegmentsBefore` are that, and they never reuse a number.
        ///
        /// Whole segments past the cut are unlinked newest first, so what is
        /// left is always a continuous prefix; the segment the cut falls
        /// inside is then shortened to the record boundary, which is what
        /// `open` already does to repair a torn tail. A crash at any point
        /// leaves a log that opens — possibly one still holding records this
        /// call was asked to drop, so call it again.
        ///
        /// `seq` may be one below the oldest record, which empties the log and
        /// leaves the sequence at `seq`. Below that it is `error.SeqTooOld`.
        ///
        /// Every slice the journal handed out before this call is invalid
        /// afterwards; subscribed sinks are not called again.
        ///
        /// Safe to call from any task or thread.
        pub fn truncateAfter(self: *Self, io: Io, seq: u64) TruncateError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.options.access == .read) return error.ReadOnly;
            if (self.persistence_failed) return error.PersistenceFailed;
            try self.log.truncateAfter(io, seq);
            self.clearTail();
            try self.fillTail(io);
        }

        /// Rewrite the log keeping only the records after `keep_after_seq`, and
        /// read it back.
        ///
        /// Whole segments are unlinked; the one segment the cut falls inside is
        /// rewritten to a neighbouring file and renamed into place, so the
        /// directory always holds a whole log. Kept records are copied byte for
        /// byte — no re-encoding, so a record read back through `migrate` or
        /// the `unknown` arm keeps the version and the payload it was written
        /// with.
        ///
        /// The sequence number continues even when nothing is kept, because a
        /// segment's name is the record that will go into it: `compact` on a
        /// journal of five records asked to keep nothing leaves an empty log
        /// whose next `append` is six.
        ///
        /// Every slice the journal handed out before this call is invalid
        /// afterwards; subscribed sinks are not called again.
        ///
        /// Safe to call from any task or thread.
        pub fn compact(self: *Self, io: Io, keep_after_seq: u64) CompactError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.options.access == .read) return error.ReadOnly;
            if (self.persistence_failed) return error.PersistenceFailed;
            try self.log.compact(io, keep_after_seq);
            self.clearTail();
            try self.fillTail(io);
        }

        /// Copy the journal into the directory `dest`, creating it if it is
        /// not there, and return the newest sequence number the copy holds.
        ///
        /// The copy is a prefix of this log and opens as a journal of its own:
        /// every sealed segment whole, the newest one up to its last complete
        /// record at the moment of the call, the sealed indexes beside their
        /// segments and the snapshot beside the log. The copy is opened by
        /// pointing `open` at `dest`, and it takes its own lock when something
        /// does.
        ///
        /// Taken by the writer this holds the journal's lock, so nothing can
        /// move underneath it. Taken by a reader beside a live writer — which
        /// is the point of calling it *hot* — the newest segment's length is
        /// measured and its newlines walked here, so the copy still ends at a
        /// record boundary however far the writer had got; records appended
        /// while it runs may or may not be in it. What a reader cannot survive
        /// is the writer unlinking a segment mid-copy, which comes back as an
        /// error rather than as a copy with a hole in it: take it again.
        ///
        /// The lock is not copied, and neither are the cursor files of named
        /// readers: those belong to the readers of *this* directory.
        ///
        /// Safe to call from any task or thread.
        pub fn backup(self: *Self, io: Io, dest: []const u8) BackupError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.options.access == .read) {
                // A reader's segment inventory is a snapshot from its last
                // open or refresh. Backup begins with a current directory
                // view so rotations completed before this call are included.
                try self.log.reload(io);
                self.clearTail();
                try self.fillTail(io);
            }
            return self.log.backup(io, dest);
        }

        //====================================================================
        // Internals.
        //====================================================================

        /// A record serialised and waiting to be written.
        ///
        /// `record` is there when something will read it: an arena owns every
        /// slice of it, and moves into `tail_arenas` once the record is on the
        /// disk. When nothing will — no tail, no sink, no round-trip check —
        /// the line is the only thing built, and the allocator owns it.
        const Built = struct {
            arena: ?std.heap.ArenaAllocator,
            bytes: []const u8,
            seq: u64,
            at: i64,
            /// This record's checksum, which the next one links back to.
            checksum: u32,
            record: ?Record,

            fn release(built: *Built, gpa: Allocator) void {
                if (built.arena) |*arena| arena.deinit() else gpa.free(built.bytes);
            }
        };

        /// Whether an appended record has to be readable in memory as well as
        /// on the disk.
        fn needsRecord(self: *const Self) bool {
            return self.options.tail_records != 0 or
                self.sinks.items.len != 0 or
                self.options.verify_round_trip;
        }

        /// Serialise one record.
        ///
        /// Where something will read the record back — a tail, a sink, or the
        /// round-trip check asked for — it is parsed back out of the bytes
        /// that will be written, so what memory holds is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append. Where nothing will, that parse would build a record
        /// and drop it unread, so it is not done.
        fn encode(self: *Self, seq: u64, at: i64, back_link: u32, event: Event) AppendError!Built {
            const line: Line = .{
                .seq = seq,
                .at = at,
                .v = self.options.schema_version,
                .p = back_link,
                .ev = event,
            };
            const body = try std.json.Stringify.valueAlloc(self.gpa, line, .{});
            defer self.gpa.free(body);
            // The checksum covers everything the record says except the
            // checksum itself. `std.json` closes the object with the one byte
            // dropped here, and `,"c":<crc>}` closes it again.
            const covered = body[0 .. body.len - 1];
            const sum = checksum(covered);
            // Checked before anything is written: a record longer than a
            // read will accept is one the log must not be given.
            if (covered.len + 32 > self.options.max_record_bytes) return error.RecordTooLarge;

            if (!self.needsRecord()) {
                const stored = try std.fmt.allocPrint(
                    self.gpa,
                    "{s},\"c\":{d}}}",
                    .{ covered, sum },
                );
                return .{
                    .arena = null,
                    .bytes = stored,
                    .seq = seq,
                    .at = at,
                    .checksum = sum,
                    .record = null,
                };
            }

            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer arena.deinit();
            const stored = try std.fmt.allocPrint(
                arena.allocator(),
                "{s},\"c\":{d}}}",
                .{ covered, sum },
            );
            const parsed = std.json.parseFromSliceLeaky(
                Line,
                arena.allocator(),
                stored,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NotRoundTrippable,
            };
            return .{
                .arena = arena,
                .bytes = stored,
                .seq = seq,
                .at = at,
                .checksum = sum,
                .record = .{
                    .seq = seq,
                    .at = at,
                    .version = self.options.schema_version,
                    .event = parsed.ev,
                    .bytes = stored,
                },
            };
        }

        /// Take a record the disk now holds into the tail and hand it to every
        /// sink, and report whether the tail took ownership of its arena.
        ///
        /// Nothing here may fail: the capacity was reserved before the write,
        /// because the disk must never hold a record memory does not.
        fn publish(self: *Self, item: Built) bool {
            self.seq = item.seq;
            const record = item.record orelse return false;
            self.tail.appendAssumeCapacity(record);
            self.tail_arenas.appendAssumeCapacity(item.arena.?);
            self.tail_bytes += record.bytes.len;
            for (self.sinks.items) |sink| sink.f(sink.ctx, record);
            return true;
        }

        /// Read the newest records back into the tail, and check that they say
        /// what the segment names say.
        fn fillTail(self: *Self, io: Io) OpenError!void {
            self.seq = self.log.lastSeq();
            const want = self.options.tail_records;
            const from = if (self.seq > want) self.seq - want else self.log.baseSeq();

            var scan = try self.log.scanFrom(io, from, true);
            defer scan.deinit(io);

            var run: Continuity = .{ .cursor = from };
            while (try scan.next(io)) |line| {
                if (scan.takeBoundary()) |boundary| try run.beginSegment(boundary);
                _ = self.scratch.reset(.retain_capacity);
                const header = try parseHeader(self.scratch.allocator(), line);
                if (!try run.accept(header)) continue;

                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                errdefer arena.deinit();
                const stored = try arena.allocator().dupe(u8, line);
                const record = try self.recordFrom(arena.allocator(), header, stored);
                try self.tail.append(self.gpa, record);
                try self.tail_arenas.append(self.gpa, arena);
                self.tail_bytes += stored.len;
                self.trimTail();
            }

            // The segment names and the records inside them have to agree, or a
            // cursor would point at a record that is not there. An empty tail
            // is right only for a log with no records in it -- which still has
            // a sequence number, because the newest segment's name carries it.
            if (self.tail.items.len != 0) {
                if (self.tail.items[self.tail.items.len - 1].seq != self.seq) return error.DiscontinuousSeq;
            } else if (want != 0 and self.log.baseSeq() != self.seq) {
                return error.DiscontinuousSeq;
            }
        }

        /// Drop the oldest records until the tail is inside both of its
        /// ceilings — at least half of it at a time, so that keeping a tail
        /// costs a constant amount per append rather than a growing one.
        fn trimTail(self: *Self) void {
            var drop: usize = 0;
            var held = self.tail_bytes;
            while (self.tail.items.len - drop > self.options.tail_records or
                (held > self.options.tail_bytes and drop < self.tail.items.len))
            {
                held -= self.tail.items[drop].bytes.len;
                drop += 1;
            }
            if (drop == 0) return;
            drop = @min(@max(drop, self.tail.items.len / 2), self.tail.items.len);

            for (self.tail_arenas.items[0..drop]) |*arena| arena.deinit();
            const kept = self.tail.items.len - drop;
            std.mem.copyForwards(Record, self.tail.items[0..kept], self.tail.items[drop..]);
            std.mem.copyForwards(
                std.heap.ArenaAllocator,
                self.tail_arenas.items[0..kept],
                self.tail_arenas.items[drop..],
            );
            self.tail.shrinkRetainingCapacity(kept);
            self.tail_arenas.shrinkRetainingCapacity(kept);

            self.tail_bytes = 0;
            for (self.tail.items) |record| self.tail_bytes += record.bytes.len;
        }

        fn clearTail(self: *Self) void {
            for (self.tail_arenas.items) |*arena| arena.deinit();
            self.tail.clearRetainingCapacity();
            self.tail_arenas.clearRetainingCapacity();
            self.tail_bytes = 0;
        }

        /// Evict records whose segment retention just removed from the log.
        fn dropTailBefore(self: *Self, first_seq: u64) void {
            var drop: usize = 0;
            while (drop < self.tail.items.len and self.tail.items[drop].seq < first_seq) : (drop += 1) {
                self.tail_bytes -= self.tail.items[drop].bytes.len;
                self.tail_arenas.items[drop].deinit();
            }
            if (drop == 0) return;

            const kept = self.tail.items.len - drop;
            std.mem.copyForwards(Record, self.tail.items[0..kept], self.tail.items[drop..]);
            std.mem.copyForwards(
                std.heap.ArenaAllocator,
                self.tail_arenas.items[0..kept],
                self.tail_arenas.items[drop..],
            );
            self.tail.shrinkRetainingCapacity(kept);
            self.tail_arenas.shrinkRetainingCapacity(kept);
        }

        /// Everything in a line except the event: what a reader needs to decide
        /// whether the event is worth parsing at all.
        const Header = struct {
            seq: u64,
            at: i64,
            version: u32,
            /// The checksum of the record before this one.
            p: u32,
            /// This record's own checksum, which the next one carries as its
            /// `p`.
            c: u32,
            /// The event, still unparsed.
            ev: Body,
        };

        /// A record's event as the header reader leaves it.
        ///
        /// A line in the shape this package writes gives up its `ev` as a
        /// slice of itself, and whatever wants the event parses that slice
        /// once. A line in some other shape has already been through
        /// `std.json` to be read at all, so its `ev` comes back as the value
        /// that parse produced.
        const Body = union(enum) {
            /// Where the event sits in the line, as a pair of offsets rather
            /// than as a slice: the line a record is built from may be a copy
            /// of the one the header was read from.
            span: struct { from: usize, to: usize },
            /// The parse that read the line, and the line it read: the value
            /// lives in the scratch that parse used, so anything that has to
            /// outlast the call reads the line again into its own arena.
            parsed: struct { value: std.json.Value, line: []const u8 },
        };

        /// Read a line's envelope, checking its checksum.
        ///
        /// `scratch` holds nothing unless the line is not in the shape this
        /// package writes, in which case it holds the parse that read it.
        fn parseHeader(scratch: Allocator, line: []const u8) ReadError!Header {
            // The checksum is the last member of every record this package
            // writes, so it is found from the end and the rest of the line is
            // what it covers. A line that does not end in one is not a record
            // and there is nothing to check it against.
            const covered = coveredBytes(line) orelse return error.CorruptRecord;
            const claimed = std.fmt.parseInt(
                u32,
                line[covered.len + ",\"c\":".len .. line.len - 1],
                10,
            ) catch return error.CorruptRecord;
            if (checksum(covered) != claimed) return error.ChecksumMismatch;

            if (quickHeader(covered, claimed)) |header| return header;
            return slowHeader(scratch, line, claimed);
        }

        /// The bytes a line's checksum covers: everything before the
        /// `,"c":<digits>}` it ends with. Null when it does not end with one.
        fn coveredBytes(line: []const u8) ?[]const u8 {
            const opening = ",\"c\":";
            if (line.len < opening.len + 2 or line[line.len - 1] != '}') return null;
            var at = line.len - 1;
            var digits: usize = 0;
            while (at > 0 and std.ascii.isDigit(line[at - 1])) : (digits += 1) at -= 1;
            if (digits == 0 or at < opening.len) return null;
            if (!std.mem.eql(u8, line[at - opening.len .. at], opening)) return null;
            return line[0 .. at - opening.len];
        }

        /// The envelope of a line in exactly the shape this package writes,
        /// read straight off the bytes. Null to say "ask `std.json`".
        ///
        /// This is the path every record of every replay takes, so it parses
        /// the four numbers itself and hands the event on as the slice it
        /// already is, rather than building a `std.json.Value` for a line
        /// that is about to be parsed into an `Event` anyway.
        fn quickHeader(covered: []const u8, claimed: u32) ?Header {
            var at: usize = 0;
            const seq = member(covered, &at, "{\"seq\":") orelse return null;
            const stamp = member(covered, &at, ",\"at\":") orelse return null;
            const version = member(covered, &at, ",\"v\":") orelse return null;
            const link = member(covered, &at, ",\"p\":") orelse return null;
            const ev_prefix = ",\"ev\":";
            if (!std.mem.startsWith(u8, covered[at..], ev_prefix)) return null;
            if (seq < 1) return null;
            return .{
                .seq = std.math.cast(u64, seq) orelse return null,
                .at = stamp,
                .version = std.math.cast(u32, version) orelse return null,
                .p = std.math.cast(u32, link) orelse return null,
                .c = claimed,
                .ev = .{ .span = .{ .from = at + ev_prefix.len, .to = covered.len } },
            };
        }

        /// One integer member, read at `at` and stepped over. Null when the
        /// member is not there, is not an integer, or does not end where a
        /// member ends.
        fn member(line: []const u8, at: *usize, comptime opening: []const u8) ?i64 {
            if (!std.mem.startsWith(u8, line[at.*..], opening)) return null;
            var end = at.* + opening.len;
            const from = end;
            if (end < line.len and line[end] == '-') end += 1;
            const digits = end;
            while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
            if (end == digits) return null;
            const value = std.fmt.parseInt(i64, line[from..end], 10) catch return null;
            at.* = end;
            return value;
        }

        /// The same envelope out of a line in some other shape: a record
        /// written by hand, or a member in another order.
        fn slowHeader(scratch: Allocator, line: []const u8, claimed: u32) ReadError!Header {
            const root = std.json.parseFromSliceLeaky(
                std.json.Value,
                scratch,
                line,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
            if (root != .object) return error.CorruptRecord;
            const seq = root.object.get("seq") orelse return error.CorruptRecord;
            const at = root.object.get("at") orelse return error.CorruptRecord;
            const v = root.object.get("v") orelse return error.CorruptRecord;
            const ev = root.object.get("ev") orelse return error.CorruptRecord;
            const back = root.object.get("p") orelse return error.CorruptRecord;
            if (seq != .integer or at != .integer or v != .integer) return error.CorruptRecord;
            if (back != .integer or seq.integer < 1) return error.CorruptRecord;
            return .{
                .seq = @intCast(seq.integer),
                .at = at.integer,
                .version = std.math.cast(u32, v.integer) orelse return error.CorruptRecord,
                .p = std.math.cast(u32, back.integer) orelse return error.CorruptRecord,
                .c = claimed,
                .ev = .{ .parsed = .{ .value = ev, .line = line } },
            };
        }

        /// Finish a header into a record whose every slice comes from `arena`.
        fn recordFrom(self: *Self, arena: Allocator, header: Header, line: []const u8) ReadError!Record {
            return .{
                .seq = header.seq,
                .at = header.at,
                .version = header.version,
                .event = try self.eventFrom(arena, header.version, header.ev, line),
                .bytes = line,
            };
        }

        fn eventFrom(
            self: *Self,
            arena: Allocator,
            version: u32,
            ev: Body,
            line: []const u8,
        ) ReadError!Event {
            if (version == self.options.schema_version) {
                return switch (ev) {
                    .span => |at| std.json.parseFromSliceLeaky(Event, arena, line[at.from..at.to], .{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.CorruptRecord,
                    },
                    .parsed => |found| std.json.parseFromValueLeaky(Event, arena, found.value, .{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.CorruptRecord,
                    },
                };
            }
            if (version > self.options.schema_version) return error.NewerSchema;
            if (self.options.migrate) |migrate| return migrate(version, try retainedEv(arena, ev, line));
            if (comptime unknown_arm != null) return unknownEvent(arena, ev, line);
            return error.OlderSchema;
        }

        /// The record's `ev` member in the record's own arena, so that what a
        /// `migrate` hook or the `unknown` arm keeps lasts as long as the
        /// record does.
        fn retainedEv(arena: Allocator, ev: Body, line: []const u8) ReadError!std.json.Value {
            const bytes = switch (ev) {
                .span => |at| line[at.from..at.to],
                // The value there belongs to the scratch that read the line.
                // The line is read again, into the arena that will hold it.
                .parsed => |found| return objectMember(arena, found.line, "ev"),
            };
            return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
        }

        fn objectMember(arena: Allocator, line: []const u8, name: []const u8) ReadError!std.json.Value {
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
            if (root != .object) return error.CorruptRecord;
            return root.object.get(name) orelse error.CorruptRecord;
        }

        fn unknownEvent(arena: Allocator, ev: Body, line: []const u8) ReadError!Event {
            switch (comptime unknown_arm.?) {
                .empty => return @unionInit(Event, "unknown", {}),
                .json_value => return @unionInit(Event, "unknown", try retainedEv(arena, ev, line)),
            }
        }

        fn readSnapshot(self: *Self, io: Io) OpenWithSnapshotError!?Snapshot {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();

            const Document = struct { seq: u64, state: []const u8 };
            const document = (self.readDocument(
                io,
                arena.allocator(),
                Document,
                Log.snapshot_name,
                self.options.max_snapshot_bytes,
                error.CorruptSnapshot,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.UnsupportedFormat => return error.UnsupportedFormat,
                error.StreamTooLong => return error.SnapshotTooLarge,
                else => return error.CorruptSnapshot,
            }) orelse return null;
            // A truncation can move the log behind a snapshot that was
            // already published. The log is authoritative; restoring state
            // from beyond its newest record would resurrect the cut history.
            if (document.seq > self.seq) return null;
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(document.state) catch return error.CorruptSnapshot;
            const state = try self.gpa.alloc(u8, size);
            errdefer self.gpa.free(state);
            decoder.decode(state, document.state) catch return error.CorruptSnapshot;
            return .{ .seq = document.seq, .state = state };
        }
    };
}

test {
    _ = @import("journal_test.zig");
}
