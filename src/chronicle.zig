//! chronicle — an append-only, replayable event log.
//!
//! One JSON object per line, each carrying a sequence number, a timestamp and
//! a schema version:
//!
//! ```
//! {"seq":1,"at":1700000000000,"v":1,"ev":{"created":{"id":7}}}
//! {"seq":2,"at":1700000000100,"v":1,"ev":{"renamed":{"id":7,"to":"b"}}}
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

/// What `Journal.open` does with a final line the previous writer did not
/// finish — the normal shape of a crash during `append`.
pub const OnTruncated = Log.OnTruncated;

/// Whether a journal may be written to, and so whether it takes the lock.
pub const Access = Log.Access;

/// The file inside a journal directory that a writer holds its advisory lock
/// on. It is never read or written.
pub const lock_name = Log.lock_name;
/// The file inside a journal directory that `Journal.snapshot` writes.
pub const snapshot_name = Log.snapshot_name;
/// The extensions of the two files that make up one segment.
pub const segment_extension = Log.segment_extension;
pub const index_extension = Log.index_extension;

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
pub fn segmentName(base_seq: u64) [Log.name_digits + segment_extension.len]u8 {
    return Log.segmentName(base_seq, segment_extension);
}

/// The CRC32C of the bytes a record's checksum covers: its line up to, but not
/// including, the `,"c":` that carries the checksum.
///
/// `append` writes it and every read verifies it. It is public so that a tool
/// reading a segment with something other than this package can check one.
pub fn checksum(covered: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(covered);
}

/// An append-only log of `Event` values.
///
/// The returned type owns a directory, the newest segment's files, an advisory
/// lock, a bounded tail of records in memory and one mutex. Create it with
/// `open` or `openWithSnapshot` and release it with `deinit`.
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
        /// true, and every `append` and `compact` is refused; see
        /// `AppendError.PersistenceFailed`. Reopening the journal is the way
        /// back.
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
            /// Whether `append` calls `fsync` before it returns. With it off, a
            /// returned sequence number means the bytes reached the operating
            /// system, not the disk.
            fsync: bool = true,
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
            /// Size of the journal's write buffer. One `append` of a record
            /// larger than this costs an extra write syscall, nothing more.
            write_buffer_size: usize = 64 * 1024,
            /// Size of the buffer a read from the disk streams through.
            read_buffer_size: usize = 64 * 1024,
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
        /// * `NewerSchema` — a record was written at a version above
        ///   `Options.schema_version`. This process is the old one.
        /// * `OlderSchema` — a record was written at a version below
        ///   `Options.schema_version` and there is neither a `migrate` hook nor
        ///   an `unknown` arm to receive it.
        pub const ReadError = Allocator.Error || MigrateError || Log.ScanError ||
            error{ ChecksumMismatch, CorruptRecord, TruncatedRecord, DiscontinuousSeq, NewerSchema, OlderSchema };

        /// `ReadError`, plus what opening a directory and taking its lock can
        /// go wrong with.
        ///
        /// * `Locked` — another process holds this journal's write lock. It is
        ///   the answer a second writer gets, instead of two writers
        ///   interleaving half-records.
        /// * `ReadOnly` — `Options.access` is `.read` and something would have
        ///   had to be written.
        pub const OpenError = ReadError || Log.OpenError;

        /// `OpenError`, plus `CorruptSnapshot` for a snapshot file that is not
        /// the object `snapshot` writes. A missing snapshot file is not an
        /// error; it yields `Opened.snapshot == null`.
        pub const OpenWithSnapshotError = OpenError || error{CorruptSnapshot};

        /// Errors from `append`.
        ///
        /// * `PersistenceFailed` — an earlier `append` could not reach the
        ///   disk. It is latched for the life of the journal, because a reader
        ///   must never see a record the disk does not have: once one record is
        ///   missing, every later one would be a lie about the order. Reopen
        ///   the journal to resume.
        /// * `NotRoundTrippable` — the event was written to JSON but did not
        ///   parse back as `Event`. Nothing was written to the file.
        /// * `SequenceExhausted` — the newest sequence number is
        ///   `maxInt(i64)`, and one more could not be read back, because a
        ///   sequence number is a JSON integer.
        /// * `ReadOnly` — the journal was opened with `Access.read`.
        pub const AppendError = Allocator.Error || Log.AppendError ||
            error{ PersistenceFailed, NotRoundTrippable, SequenceExhausted };

        /// Errors from `replay`, and from the `Replay` it returns.
        pub const ReplayError = ReadError;

        /// Errors from `subscribe` and `subscribeFrom`, which replay the
        /// records a cursor has missed before they register the sink.
        pub const SubscribeError = ReplayError || Io.Cancelable;

        /// Errors from `snapshot`.
        pub const SnapshotError = Allocator.Error || Log.SnapshotError;

        /// Errors from `compact`. It re-reads the journal it has just written,
        /// so every `OpenError` is possible.
        pub const CompactError = OpenError || Log.CompactError || error{PersistenceFailed};

        /// Errors from `dropSegmentsBefore`.
        pub const DropError = Log.CompactError;

        /// The line, as written. Field order here is the field order on disk.
        const Line = struct {
            seq: u64,
            at: i64,
            v: u32,
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
                .fsync = options.fsync,
                .write_buffer_size = options.write_buffer_size,
                .read_buffer_size = options.read_buffer_size,
                .max_segment_bytes = options.max_segment_bytes,
                .max_segment_records = options.max_segment_records,
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

        /// Flush, close every file, release the lock and release every
        /// allocation. Every slice the journal handed out is invalid
        /// afterwards.
        pub fn deinit(self: *Self, io: Io) void {
            self.log.deinit(io);
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
        /// The record kept in memory is parsed back out of the bytes that were
        /// written, so it owns its own memory and is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append.
        ///
        /// Nothing is published unless the bytes reached the disk. If the
        /// write, the flush or the `fsync` fails, the error comes back, no
        /// record is added, no sink is called, and every later `append` returns
        /// `error.PersistenceFailed`.
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
            const line: Line = .{ .seq = next, .at = at, .v = self.options.schema_version, .ev = event };
            const body = try std.json.Stringify.valueAlloc(self.gpa, line, .{});
            defer self.gpa.free(body);
            // The checksum covers everything the record says except the
            // checksum itself. `std.json` closes the object with the one byte
            // dropped here, and `,"c":<crc>}` closes it again.
            const covered = body[0 .. body.len - 1];
            const encoded = try std.fmt.allocPrint(
                self.gpa,
                "{s},\"c\":{d}}}",
                .{ covered, checksum(covered) },
            );
            defer self.gpa.free(encoded);

            // Built before the write: a record the journal could not hold is a
            // record that must not reach the disk either.
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            errdefer arena.deinit();
            const stored = try arena.allocator().dupe(u8, encoded);
            const parsed = std.json.parseFromSliceLeaky(
                Line,
                arena.allocator(),
                stored,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NotRoundTrippable,
            };
            // Reserve before writing: after the bytes are durable nothing may
            // fail, or the disk would hold a record memory does not.
            try self.tail.ensureUnusedCapacity(self.gpa, 1);
            try self.tail_arenas.ensureUnusedCapacity(self.gpa, 1);

            {
                errdefer self.persistence_failed = true;
                try self.log.appendLine(io, stored);
            }

            const record: Record = .{
                .seq = next,
                .at = at,
                .version = self.options.schema_version,
                .event = parsed.ev,
                .bytes = stored,
            };
            self.tail.appendAssumeCapacity(record);
            self.tail_arenas.appendAssumeCapacity(arena);
            self.tail_bytes += stored.len;
            self.seq = next;

            for (self.sinks.items) |sink| sink.f(sink.ctx, record);
            self.changed.broadcast(io);
            // Last, so that a sink reading this record was reading memory that
            // still existed.
            self.trimTail();
            return next;
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

        /// What `replay` returns: a walk over the log from the disk.
        pub const Replay = struct {
            journal: *Self,
            scan: Log.Scan,
            /// Holds the record `next` last returned, and nothing else.
            arena: std.heap.ArenaAllocator,
            /// Its own, so that two walks and an `append` never share one.
            scratch: std.heap.ArenaAllocator,
            cursor: u64,
            expected: ?u64,

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
                    _ = walk.scratch.reset(.retain_capacity);
                    const header = try parseHeader(walk.scratch.allocator(), line);
                    // The walk may have started a little before the cursor,
                    // because a segment is the unit a seek lands in. Skipping
                    // before the event is parsed is what lets a reader hold a
                    // cursor into a log whose events it does not know.
                    if (header.seq <= walk.cursor) continue;
                    if (walk.expected) |want| {
                        if (header.seq != want) return error.DiscontinuousSeq;
                    }
                    _ = walk.arena.reset(.retain_capacity);
                    const record = try walk.journal.recordFrom(walk.arena.allocator(), header, line);
                    walk.expected = header.seq + 1;
                    return record;
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
        pub fn replay(self: *Self, io: Io, cursor: u64) ReplayError!Replay {
            return .{
                .journal = self,
                .scan = try self.log.scanFrom(io, cursor),
                .arena = .init(self.gpa),
                .scratch = .init(self.gpa),
                .cursor = cursor,
                .expected = null,
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

        /// Register a fold and hand it every record the journal holds, then
        /// every record appended afterwards.
        ///
        /// A fold built this way is built the same way whether the records came
        /// off the disk or arrived live, which is the point.
        ///
        /// The sink is called with the journal's lock held and lives until
        /// `deinit`; there is no unsubscribe.
        pub fn subscribe(self: *Self, io: Io, sink: Sink) SubscribeError!void {
            return self.subscribeFrom(io, sink, 0);
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
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try self.sinks.append(self.gpa, sink);
            errdefer _ = self.sinks.pop();

            var delivered = cursor;
            if (!self.since(cursor).complete) {
                var walk = try self.replay(io, cursor);
                defer walk.deinit(io);
                while (try walk.next(io)) |record| {
                    sink.f(sink.ctx, record);
                    delivered = record.seq;
                }
            }
            for (self.since(delivered).records) |record| sink.f(sink.ctx, record);
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
            const b64 = try self.gpa.alloc(u8, encoder.calcSize(state_bytes.len));
            defer self.gpa.free(b64);
            _ = encoder.encode(b64, state_bytes);

            const document = try std.json.Stringify.valueAlloc(
                self.gpa,
                .{ .seq = self.seq, .state = b64 },
                .{},
            );
            defer self.gpa.free(document);

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
            return self.log.dropSegmentsBefore(io, seq);
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

        //====================================================================
        // Internals.
        //====================================================================

        /// Read the newest records back into the tail, and check that they say
        /// what the segment names say.
        fn fillTail(self: *Self, io: Io) OpenError!void {
            self.seq = self.log.lastSeq();
            const want = self.options.tail_records;
            const from = if (self.seq > want) self.seq - want else self.log.baseSeq();

            var scan = try self.log.scanFrom(io, from);
            defer scan.deinit(io);

            var expected: ?u64 = null;
            while (try scan.next(io)) |line| {
                _ = self.scratch.reset(.retain_capacity);
                const header = try parseHeader(self.scratch.allocator(), line);
                if (expected) |value| {
                    if (header.seq != value) return error.DiscontinuousSeq;
                } else if (header.seq <= from) {
                    // The seek landed before the cursor, which a segment
                    // boundary makes normal: drop what is already behind,
                    // without going as far as parsing its event.
                    continue;
                }
                expected = header.seq + 1;

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

        /// Everything in a line except the event: what a reader needs to decide
        /// whether the event is worth parsing at all.
        const Header = struct {
            seq: u64,
            at: i64,
            version: u32,
            /// Borrowed from the `scratch` it was parsed into, so it lasts
            /// until that arena is next reset.
            ev: std.json.Value,
        };

        /// Read a line's envelope into `scratch`.
        fn parseHeader(scratch: Allocator, line: []const u8) ReadError!Header {
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
            if (seq != .integer or at != .integer or v != .integer) return error.CorruptRecord;
            if (seq.integer < 1) return error.CorruptRecord;
            const version = std.math.cast(u32, v.integer) orelse return error.CorruptRecord;
            // The checksum, when the record carries one. A record written
            // before 0.3.0 does not, and is read exactly as it always was.
            if (root.object.get("c")) |claimed| {
                if (claimed != .integer) return error.CorruptRecord;
                const want = std.math.cast(u32, claimed.integer) orelse return error.CorruptRecord;
                var buffer: [32]u8 = undefined;
                const suffix = std.fmt.bufPrint(&buffer, ",\"c\":{d}}}", .{want}) catch unreachable;
                // The checksum is the last member of a line this package
                // wrote, so a line that does not end in the one it claims is
                // not one -- and there is nothing to check it against.
                if (!std.mem.endsWith(u8, line, suffix)) return error.CorruptRecord;
                if (checksum(line[0 .. line.len - suffix.len]) != want) return error.ChecksumMismatch;
            }
            return .{
                .seq = @intCast(seq.integer),
                .at = at.integer,
                .version = version,
                .ev = ev,
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
            ev: std.json.Value,
            line: []const u8,
        ) ReadError!Event {
            if (version == self.options.schema_version) {
                return std.json.parseFromValueLeaky(Event, arena, ev, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptRecord,
                };
            }
            if (version > self.options.schema_version) return error.NewerSchema;
            if (self.options.migrate) |migrate| return migrate(version, try retainedEv(arena, line));
            if (comptime unknown_arm != null) return unknownEvent(arena, line);
            return error.OlderSchema;
        }

        /// The record's `ev` member parsed into the record's own arena, so that
        /// what a `migrate` hook or the `unknown` arm keeps lasts as long as
        /// the record does.
        fn retainedEv(arena: Allocator, line: []const u8) ReadError!std.json.Value {
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
            if (root != .object) return error.CorruptRecord;
            return root.object.get("ev") orelse error.CorruptRecord;
        }

        fn unknownEvent(arena: Allocator, line: []const u8) ReadError!Event {
            switch (comptime unknown_arm.?) {
                .empty => return @unionInit(Event, "unknown", {}),
                .json_value => return @unionInit(Event, "unknown", try retainedEv(arena, line)),
            }
        }

        fn readSnapshot(self: *Self, io: Io) OpenWithSnapshotError!?Snapshot {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();

            const bytes = self.log.dir.readFileAlloc(
                io,
                Log.snapshot_name,
                arena.allocator(),
                .unlimited,
            ) catch |err| switch (err) {
                error.FileNotFound => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return error.CorruptSnapshot,
            };
            const Document = struct { seq: u64, state: []const u8 };
            const document = std.json.parseFromSliceLeaky(
                Document,
                arena.allocator(),
                bytes,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptSnapshot,
            };
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
