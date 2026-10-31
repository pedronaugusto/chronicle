//! The private state and operations behind the managed owners.
//! chronicle.zig is the package API, and documents every declaration it
//! hands out; this file documents only what it keeps to itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const continuity = @import("journal/continuity.zig");
const Log = @import("journal/Log.zig");
const Crc32c = @import("warp").Crc32c;
const aegis = @import("aegis");
const jsonl = @import("journal/jsonl.zig");
const strand = jsonl.strand;
const json = strand.json;
const envelope = @import("journal/envelope.zig");
const Encoding = @import("journal/Encoding.zig");
const values = @import("journal/values.zig");
const streams = @import("journal/streams.zig");

pub const Seq = values.Seq;
pub const Bytes = values.Bytes;
pub const Records = values.Records;
pub const Time = values.Time;
pub const Stream = streams.Stream;
pub const StreamVersion = streams.StreamVersion;
pub const no_version = streams.no_version;

/// A record's place in its stream.
pub const StreamAt = struct {
    id: []const u8,
    version: StreamVersion,
};
pub const beginning = values.beginning;

pub const Raw = json.Raw;

pub const OnTruncated = Log.OnTruncated;

pub const Access = Log.Access;

pub const Sync = Log.Sync;

pub const Flush = Log.Flush;

pub const flush: Flush = Log.flush;

pub const lock_name = Log.lock_name;
pub const snapshot_name = Log.snapshot_name;
pub const segment_extension = Log.segment_extension;
pub const index_extension = Log.index_extension;
pub const cursor_extension = Log.cursor_extension;

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

pub fn segmentName(base_seq: Seq) [Log.name_digits + segment_extension.len:0]u8 {
    return Log.segmentName(segment_extension, base_seq);
}

pub fn indexName(base_seq: Seq) [Log.name_digits + index_extension.len:0]u8 {
    return Log.segmentName(index_extension, base_seq);
}

pub const document_format: u32 = 1;

/// The documents beside the log, as they are written: the format first, so a
/// reader knows which shape the rest is before it reads it.
const CursorDocument = struct { fmt: u32, seq: u64 };
const SnapshotDocument = struct { fmt: u32, seq: u64, state: []const u8 };

pub fn checksum(covered: []const u8) u32 {
    return Crc32c.hash(covered);
}

pub const Position = struct {
    /// The reader has every record up to and including this sequence
    /// number: what it would pass to `replay`.
    cursor: Seq,
    /// The last record the walk read, handed on or stepped over; null when
    /// it read none, in which case `replayAt` is `replay` from `cursor`.
    last: ?Last = null,

    pub const Last = struct {
        seq: Seq,
        /// The segment holding it, by the sequence number it is named after.
        segment: Seq,
        /// Where its line starts in the segment's file, and where the next
        /// one starts.
        start: Bytes,
        end: Bytes,
        /// Its checksum, which the record after it carries as its back-link.
        checksum: u32,
    };

    /// A position that is only a cursor: `replayAt` from it is `replay`.
    pub fn after(cursor: Seq) Position {
        return .{ .cursor = cursor };
    }
};

pub fn Journal(comptime Event: type) type {
    return struct {
        const Self = @This();

        // Only the journal facade hands out access to this state.

        /// The configuration supplied at open, which a caller sees through
        /// `openedWith`. Fixed for the journal's life, so the journal itself
        /// reads it without the lock.
        config: Options,

        //-------------------------------------------------------------- internals

        /// The allocator every allocation comes from. Owned by the caller; the
        /// journal never outlives it.
        gpa: Allocator,
        /// Everything that changes once the journal is open, behind the one
        /// lock. Reached only through a guard, which is what a helper that
        /// needs the lock asks for in its signature.
        state: aegis.BlockingGuarded(State),
        /// Signaled under the lock by every append and every nudge, and
        /// waited on by `waitPast`. aegis's condition rather than a futex word
        /// of this package's: it takes a cancel that lands in the same
        /// instant as a signal for the cancel, so a reader stopped as a
        /// record arrives is stopped.
        changed: aegis.Condition,

        /// What the lock guards.
        const State = struct {
            /// A failed persistence operation refuses writes until reconciliation.
            write_failed: bool,
            /// The segments, the indexes, the lock and the directory.
            log: Log,
            /// The newest records, oldest first. A record and the arena owning
            /// every slice in it enter and leave the tail together.
            tail: Tail,
            /// The length of the last record encoded, which sizes the next one's
            /// buffer.
            record_hint: usize,
            /// The line of a record nothing keeps — no tail, no sink, no
            /// round-trip check — written here and handed to the log, which
            /// copies it. Reused, so once it has held a record that long such an
            /// append allocates nothing.
            line: std.ArrayList(u8),
            sinks: std.ArrayList(Sink),
            /// Bumped by `nudge`: a wake with no record behind it.
            nudges: u64,
            /// The sequence number of the newest record, or zero. Read it with
            /// `lastSeq`, which takes the lock.
            seq: Seq,
            /// The streams: the active segment's, the heads looked up, and
            /// where each truncated stream now starts.
            streams: streams.Book,

            /// Refuse a conditional append whose journal has moved on. Called
            /// after everything that says the journal cannot be appended to at
            /// all, and before anything is written.
            fn expect(s: *const State, expected: ?Expected) error{WrongExpectedSeq}!void {
                const want = expected orelse return;
                if (s.seq == want.last) return;
                if (want.found) |found| found.* = s.seq;
                return error.WrongExpectedSeq;
            }

            /// Take back the lines of a batch that was staged and never
            /// committed, so that a batch which could not be formed leaves the
            /// log exactly as it was. Nothing staged was published, so the tail
            /// and the sinks never saw it.
            ///
            /// What is on the disk has to end at a record boundary whatever
            /// happened. Nothing here was ever acknowledged, so nothing is lost
            /// by it.
            fn unstage(s: *State, io: Io, from: Log.Mark) void {
                // The records taken back may have been noted in the book.
                s.streams.stale = true;
                s.log.discardStaged(io, from) catch {
                    // The log could not be put back. What this process staged
                    // may reach the disk as records it never acknowledged, so it
                    // must not append after them until `reconcile` has read
                    // what is there.
                    s.write_failed = true;
                };
            }

            /// The tail after a cursor. The window borrows the state: it is good
            /// until the guard it came from is released.
            fn tailSince(s: *const State, cursor: Seq) TailWindow {
                const items = s.tail.entries.items;
                if (items.len == 0) return .{ .records = items, .complete = !values.below(cursor, s.seq) };
                const first = items[0].record.seq;
                // The tail starts one record after `tail_base`; a cursor behind
                // that has fallen off the front of it.
                if (values.below(cursor, values.predecessor(first) orelse values.beginning)) return .{ .records = items, .complete = false };
                // The records the cursor has already passed: found by number,
                // since a removed record's stub leaves a gap in the tail.
                const skip = std.sort.partitionPoint(OwnedRecord, items, cursor, struct {
                    fn atOrBefore(c: Seq, item: OwnedRecord) bool {
                        return values.atMost(item.record.seq, c);
                    }
                }.atOrBefore);
                return .{ .records = items[skip..], .complete = true };
            }

            fn clearTail(s: *State) void {
                s.tail.removePrefix(s.tail.entries.items.len);
            }

            /// Evict records whose segment retention just removed from the log.
            fn dropTailBefore(s: *State, first_seq: Seq) void {
                var drop: usize = 0;
                while (drop < s.tail.entries.items.len and values.below(s.tail.entries.items[drop].record.seq, first_seq)) : (drop += 1) {}
                s.tail.removePrefix(drop);
            }
        };

        pub const Record = struct {
            /// Position in the log. The first record of a journal that has
            /// never been compacted is 1, and it rises by one per record. It is
            /// written as a JSON integer, so `maxInt(i64)` is the last one a
            /// journal can hold; see `AppendError.SequenceExhausted`.
            seq: Seq,
            /// Whatever the appender passed as `at`: milliseconds since the
            /// Unix epoch. chronicle never reads a clock.
            at: Time,
            /// The schema version this record was written at. Equal to the
            /// journal's `Options.schema_version` unless it was written by an
            /// older writer and read back through `Options.migrate` or the
            /// `unknown` arm.
            version: u32,
            /// Its stream and its version in it, or null for a record in no
            /// stream. The id is a slice of `bytes`.
            stream: ?StreamAt = null,
            /// The parsed event.
            event: Event,
            /// This record's exact line on disk, without the trailing newline.
            /// Appending it to a stream reproduces the durable form with no
            /// re-encoding.
            bytes: []const u8,
        };

        /// Only the batch facade hands out access to this state.
        pub const Batch = struct {
            /// The records, oldest first. Empty when the cursor is caught up.
            records: []const Record,
            /// Whether no records between the cursor and the newest sequence
            /// known at the time of the copy are missing. False means the
            /// tail no longer reaches back that far: use `replay` or
            /// `subscribeFrom` to read the disk.
            complete: bool,
            // Managed JSON containers retain this allocator's context. The
            // batch is allocated before its arena hands out any storage.
            arena: std.heap.ArenaAllocator,

            /// Release every record and all its referenced data together.
            pub fn deinit(batch: *Batch) void {
                batch.arena.deinit();
                batch.* = undefined;
            }
        };

        /// One tail entry owns its record and all the memory it references.
        const OwnedRecord = struct {
            record: Record,
            arena: *std.heap.ArenaAllocator,
        };

        /// Allocator contexts retained by events must survive moving owners.
        fn createArena(gpa: Allocator) Allocator.Error!*std.heap.ArenaAllocator {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            return arena;
        }

        fn destroyArena(arena: *std.heap.ArenaAllocator) void {
            const gpa = arena.child_allocator;
            arena.deinit();
            gpa.destroy(arena);
        }

        /// The bounded cache owns its entries and their byte count together.
        /// A rebuild is a separate cache until it has read the log whole.
        const Tail = struct {
            entries: std.ArrayList(OwnedRecord) = .empty,
            bytes: usize = 0,

            fn deinit(tail: *Tail, gpa: Allocator) void {
                tail.removePrefix(tail.entries.items.len);
                tail.entries.deinit(gpa);
                tail.* = .{};
            }

            fn appendAssumeCapacity(tail: *Tail, owned: OwnedRecord) void {
                std.debug.assert(tail.entries.items.len < tail.entries.capacity);
                if (tail.entries.items.len != 0) {
                    std.debug.assert(values.below(tail.entries.items[tail.entries.items.len - 1].record.seq, owned.record.seq));
                }
                tail.entries.appendAssumeCapacity(owned);
                tail.bytes += owned.record.bytes.len;
            }

            fn trim(tail: *Tail, options: Options) void {
                var drop: usize = 0;
                var held = tail.bytes;
                while (tail.entries.items.len - drop > values.limit(options.tail_records) or
                    (held > values.limit(options.tail_bytes) and drop < tail.entries.items.len))
                {
                    held -= tail.entries.items[drop].record.bytes.len;
                    drop += 1;
                }
                if (drop == 0) return;
                drop = @min(@max(drop, tail.entries.items.len / 2), tail.entries.items.len);
                tail.removePrefix(drop);
            }

            /// Release the prefix and move the surviving owners together.
            fn removePrefix(tail: *Tail, drop: usize) void {
                std.debug.assert(drop <= tail.entries.items.len);
                if (drop == 0) return;
                for (tail.entries.items[0..drop]) |*owned| {
                    tail.bytes -= owned.record.bytes.len;
                    destroyArena(owned.arena);
                }
                const kept = tail.entries.items.len - drop;
                @memmove(tail.entries.items[0..kept], tail.entries.items[drop..]);
                tail.entries.shrinkRetainingCapacity(kept);
            }
        };

        /// A borrow used only while holding the journal's lock.
        const TailWindow = struct {
            records: []const OwnedRecord,
            complete: bool,
        };

        pub const Entry = struct {
            /// Stored as given; chronicle never reads a clock.
            at: Time,
            event: Event,
        };

        pub const Sink = struct {
            ctx: *anyopaque,
            f: *const fn (*anyopaque, Record) void,
        };

        pub const MigrateError = error{ OutOfMemory, Unmigratable };

        pub const Migrate = *const fn (arena: Allocator, from_version: u32, event: Raw) MigrateError!Event;

        pub const Options = struct {
            /// The version stamped into every record `append` writes, and the
            /// version records are expected to be at when read back.
            schema_version: u32 = 1,
            /// Whether this process writes to the journal at all. `.write`
            /// takes the exclusive advisory lock, and a second writer gets
            /// `error.Locked`; `.read` takes no lock, writes nothing, and is
            /// safe to run beside the writer.
            access: Access = .write,
            /// What to do with a final record the previous writer did not
            /// finish (see `OnTruncated`). Ignored under
            /// `.read`, which repairs nothing.
            on_truncated: OnTruncated = .drop,
            /// How much of the log `open` reads back before it returns.
            verify: Verify = .quick,
            /// Called for a record written at a version below
            /// `schema_version`. Without it, such a record becomes the `Event`
            /// arm named `unknown` if there is one — typed `void`, `Raw` or
            /// `strand.json.Value` — and `error.OlderSchema` if there is not.
            migrate: ?Migrate = null,
            /// How often `append` makes the bytes it wrote durable. The
            /// default is the durable one; README.md states what each level
            /// promises and what it gives up.
            sync: Sync = .always,
            /// How many of the newest records to keep in memory for
            /// `copySince` and subscriptions. Older ones come from the disk.
            /// Zero is allowed: then `replay` and `subscribe` are the ways to read.
            tail_records: Records = .fromRaw(1024),
            /// A second ceiling on the tail, over the records' bytes, for a
            /// journal whose records are large. Whichever bites first wins.
            tail_bytes: Bytes = .fromRaw(1024 * 1024),
            /// How large a segment may grow before the next `append` starts a
            /// new one. It is also how much of the log `open` reads.
            max_segment_bytes: Bytes = .fromRaw(8 * 1024 * 1024),
            /// A second ceiling on a segment, over records. Null is none.
            max_segment_records: ?Records = null,
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
            preallocate_bytes: Bytes = .fromRaw(0),
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
            index_interval_bytes: Bytes = .fromRaw(4096),
            /// How long a record's line may be.
            ///
            /// `append` refuses a longer one, and a read refuses a segment
            /// with no newline within that many bytes — which is what stops
            /// a damaged segment being taken into memory whole to find out
            /// that it holds no record.
            max_record_bytes: Bytes = .fromRaw(1024 * 1024),
            /// How many streams' newest versions to keep in memory, past those
            /// of the active segment: the ones touched most recently. A
            /// stream not among them is looked up in the sealed segments'
            /// stream indexes, a filter probe each and one read of each that
            /// may hold it. Memory is a few hundred bytes a stream, whatever
            /// number of streams the journal holds.
            stream_heads: u32 = 4096,
            /// How large a snapshot file may be to be written or read back. It holds
            /// whatever a fold serialises to, so this is the caller's number
            /// and not the package's; a larger one is
            /// `error.SnapshotTooLarge`.
            max_snapshot_bytes: Bytes = .fromRaw(64 * 1024 * 1024),
            /// Size of the journal's write buffer. One `append` of a record
            /// larger than this costs an extra write syscall, nothing more.
            write_buffer_size: Bytes = .fromRaw(64 * 1024),
            /// Size of the buffer a read from the disk streams through.
            /// Zero uses one byte, the lookahead needed to recognize a line.
            read_buffer_size: Bytes = .fromRaw(64 * 1024),
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
            /// The executor airlock runs the journal's syncs on, every one of
            /// them (`airlock.Blocking`). A sync holds the thread that makes
            /// it until the drive answers: on an evented `Io` that thread is
            /// a worker other tasks are waiting for, so a program on a
            /// reactor runtime gives its sync lane: a `Blocking` it keeps,
            /// `reactor.syncLaneFor(airlock.Blocking)`, by its address. Null
            /// makes them on the calling thread.
            blocking: ?*Log.Blocking = null,
        };

        pub const Snapshot = struct {
            seq: Seq,
            state: []const u8,
            /// Private: the allocator `openWithSnapshot` was given, which
            /// owns `state`.
            gpa: Allocator,

            /// Free `state`.
            pub fn deinit(found: Snapshot) void {
                found.gpa.free(found.state);
            }
        };

        pub const ReadError = Allocator.Error || MigrateError || Log.ScanError ||
            error{ ChecksumMismatch, CorruptRecord, TruncatedRecord, DiscontinuousSeq, BrokenChain, BrokenBatch, NewerSchema, OlderSchema };

        pub const OpenError = ReadError || Log.OpenError;

        pub const OpenWithSnapshotError = OpenError || error{ CorruptSnapshot, SnapshotTooLarge };

        pub const AppendError = Allocator.Error || Log.StageError ||
            error{ PersistenceFailed, NotRoundTrippable, RecordTooLarge };

        pub const AppendIfError = AppendError || error{WrongExpectedSeq};

        pub const Expected = struct {
            /// The sequence number the newest record must still have: zero
            /// for a journal that must still be empty.
            last: Seq,
            /// Where `error.WrongExpectedSeq` leaves the sequence number the
            /// newest record has instead, read under the same lock as the
            /// comparison. Not written when the append goes ahead.
            found: ?*Seq = null,
        };

        pub const Commit = enum {
            /// One sync for the batch, and no more: a crash inside it leaves
            /// a prefix of it on the disk.
            group,
            /// One sync for the batch, and all of it or none of it: every
            /// record names the batch, and an open that finds the log ending
            /// inside one drops it whole. The batch stays in one segment.
            atomic,
        };

        pub const ReconcileError = OpenError;

        pub const ReplayError = ReadError;

        pub const CopyError = Allocator.Error || Io.Cancelable;

        pub const ReplayAtError = ReplayError || error{StalePosition};

        pub const SeekError = OpenError;

        pub const SubscribeError = ReplayError || Io.Cancelable || error{HistoryDropped};

        pub const SnapshotError = Allocator.Error || Log.SnapshotError || error{SnapshotTooLarge};

        pub const FinishError = Log.FinishError;

        pub const TailerError = Allocator.Error || Io.Cancelable ||
            Log.WriteFileError || error{ InvalidName, CorruptCursor, UnsupportedFormat };

        pub const CompactError = OpenError || Log.CompactError || Log.WriteFileError || error{PersistenceFailed};

        pub const DropError = Log.CompactError || ReadError || Log.WriteFileError;

        pub const BackupError = OpenError || Log.BackupError;

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

        /// `Line` for a record of an atomic batch: the first and the last
        /// sequence numbers of the batch, between the back-link and the event.
        const LineInBatch = struct {
            seq: u64,
            at: i64,
            v: u32,
            p: u32,
            bf: u64,
            bl: u64,
            ev: Event,
        };

        /// `Line` for a record in a stream: its id and its version in it,
        /// between the back-link and the event.
        const LineInStream = struct {
            seq: u64,
            at: i64,
            v: u32,
            p: u32,
            s: []const u8,
            sv: u64,
            ev: Event,
        };

        /// `LineInBatch` for a record in a stream.
        const LineInStreamBatch = struct {
            seq: u64,
            at: i64,
            v: u32,
            p: u32,
            bf: u64,
            bl: u64,
            s: []const u8,
            sv: u64,
            ev: Event,
        };

        /// The stream id inside a line written for it: `"s":"<id>"` is
        /// written once, before the event, so its first occurrence is it.
        fn idIn(line: []const u8, id: []const u8) []const u8 {
            const marker = "\"s\":\"";
            const at = std.mem.find(u8, line, marker).? + marker.len;
            return line[at..][0..id.len];
        }

        const UnknownArm = enum { empty, raw, json_value };

        /// Whether `Event` has an arm this package can put an unrecognised
        /// older record into, and what shape it is.
        /// How an event is parsed out of its record: by every read, and by
        /// the append that proves the event reads back. One value, so an
        /// append never writes what a read refuses. Strict, because an event
        /// that writes a member it does not read back would not come back
        /// as the event that was appended.
        fn eventParse(line_bytes: usize) json.ParseOptions {
            return .{ .limits = .sized(line_bytes) };
        }

        const unknown_arm: ?UnknownArm = blk: {
            if (@typeInfo(Event) != .@"union" or !@hasField(Event, "unknown")) break :blk null;
            const Arm = @FieldType(Event, "unknown");
            if (Arm == void) break :blk .empty;
            if (Arm == Raw) break :blk .raw;
            if (Arm == json.Value) break :blk .json_value;
            break :blk null;
        };

        //====================================================================
        // Opening.
        //====================================================================

        /// Opens the journal in `self`, where it stays until its `deinit`:
        /// its log's handles are bound to where it is.
        pub fn open(self: *Self, gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!void {
            try self.openUnsettled(gpa, io, path, options);
            errdefer self.abandon(io);
            try self.settle(io);
        }

        /// `open` up to the repairs the log found (`Log.settle`): a caller
        /// that may still refuse the journal settles once it has accepted it,
        /// and `abandon` leaves the files as they were found.
        fn openUnsettled(self: *Self, gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!void {
            self.* = .{
                .gpa = gpa,
                .config = options,
                .state = .init(.{
                    // Opened below, where it stays: its handles' owners
                    // are bound to where the log is.
                    .log = undefined,
                    .tail = .{},
                    .record_hint = 256,
                    .line = .empty,
                    .sinks = .empty,
                    .nudges = 0,
                    .seq = values.beginning,
                    .streams = .init(gpa, options.stream_heads),
                    .write_failed = false,
                }),
                .changed = .initLimit(std.math.maxInt(usize)),
            };
            {
                // No other task has the journal yet.
                var guard = self.state.acquireUncancelable(io);
                defer guard.deinit(io);
                try guard.value().log.open(gpa, io, path, .{
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
                    .blocking = options.blocking,
                });
            }
            errdefer {
                // No other task has the journal yet, and a refused open leaves
                // the log as it found it.
                const s = self.state.teardown();
                s.log.abandon(io);
                self.release(s);
            }
            {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                try self.fillTail(s, io);
                try self.loadTruncations(s, io);
            }
            if (options.verify == .full) _ = try self.verify(io);
        }

        /// `open`, and the snapshot the journal holds.
        pub fn openWithSnapshot(
            self: *Self,
            gpa: Allocator,
            io: Io,
            path: []const u8,
            options: Options,
        ) OpenWithSnapshotError!?Snapshot {
            try self.openUnsettled(gpa, io, path, options);
            errdefer self.abandon(io);
            const found = snapshot_read: {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                break :snapshot_read try self.readSnapshot(s, io);
            };
            try self.settle(io);
            return found;
        }

        fn settle(self: *Self, io: Io) OpenError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            try guard.value().log.settle(io);
        }

        pub fn finish(self: *Self, io: Io) FinishError!void {
            // A finish that has begun flushes and seals to its end, whatever
            // a cancel asks of the task meanwhile.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            var guard = self.state.acquireUncancelable(io);
            defer guard.deinit(io);
            const s = guard.value();
            try s.log.finish(io);
        }

        pub fn deinit(self: *Self, io: Io) void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            var guard = self.state.acquireUncancelable(io);
            defer guard.deinit(io);
            const s = guard.value();
            s.log.deinit(io);
            self.release(s);
        }

        /// `deinit` for a journal whose open its caller refused: the log let
        /// go as it was found (`Log.abandon`).
        fn abandon(self: *Self, io: Io) void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            var guard = self.state.acquireUncancelable(io);
            defer guard.deinit(io);
            const s = guard.value();
            s.log.abandon(io);
            self.release(s);
        }

        fn release(self: *Self, s: *State) void {
            s.streams.deinit();
            s.clearTail();
            s.tail.deinit(self.gpa);
            s.line.deinit(self.gpa);
            s.sinks.deinit(self.gpa);
        }

        //====================================================================
        // Writing.
        //====================================================================

        pub fn append(self: *Self, io: Io, at: Time, event: Event) AppendError!Seq {
            return self.appendOne(io, null, false, {}, at, event, .now) catch |err| switch (err) {
                error.WrongExpectedSeq => aegis.assert.never("an append that expects no sequence number never mismatches one"),
                else => |e| return e,
            };
        }

        pub fn appendDeferred(self: *Self, io: Io, at: Time, event: Event) AppendError!Seq {
            return self.appendOne(io, null, false, {}, at, event, .deferred) catch |err| switch (err) {
                error.WrongExpectedSeq => aegis.assert.never("an append that expects no sequence number never mismatches one"),
                else => |e| return e,
            };
        }

        pub fn appendIf(self: *Self, io: Io, expected: Expected, at: Time, event: Event) AppendIfError!Seq {
            return self.appendOne(io, expected, false, {}, at, event, .now);
        }

        /// The error and the result of an append, into a stream or not.
        fn AppendResult(comptime streamed: bool) type {
            return if (streamed) StreamAppendError!Appended else AppendIfError!Seq;
        }

        fn appendOne(self: *Self, io: Io, expected: ?Expected, comptime streamed: bool, in: if (streamed) Target else void, at: Time, event: Event, durability: enum { now, deferred }) AppendResult(streamed) {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            // A journal opened for reading is refused before anything else: it
            // is not a journal that has failed, and it must not be latched as
            // one.
            if (self.config.access == .read) return error.ReadOnly;
            if (s.write_failed) return error.PersistenceFailed;
            if (!streamed) try s.expect(expected);
            const place: ?StreamAt = if (streamed) .{ .id = in.stream.bytes, .version = (try self.placeAppend(s, io, in, 1)).last } else null;
            const next = try values.successor(s.seq);
            // Built before the write: a record the journal could not hold is a
            // record that must not reach the disk either.
            var built = try self.encode(s, next, at, s.log.chainTip(), event, null, place);
            var held = false;
            defer if (!held) built.release();

            // Reserve before writing: after the bytes are durable nothing may
            // fail, or the disk would hold a record memory does not.
            if (self.keepsRecords(s)) try s.tail.entries.ensureUnusedCapacity(self.gpa, 1);

            {
                errdefer s.write_failed = true;
                switch (durability) {
                    .now => try s.log.appendLine(io, built.bytes, built.at, built.checksum),
                    .deferred => {
                        try s.log.stageLine(io, built.bytes, built.at, built.checksum, .may_rotate);
                        try s.log.commitDeferred();
                    },
                }
            }
            self.noteStaged(s, io, place, next, built.bytes.len);

            held = self.publish(s, built);
            self.wake(io);
            // Last, so that a sink reading this record was reading memory that
            // still existed.
            self.trimTail(s);
            return if (streamed) .{ .seq = next, .version = place.?.version } else next;
        }

        pub fn appendAll(self: *Self, io: Io, entries: []const Entry, commit: Commit) AppendError!Seq {
            return self.appendBatch(io, null, false, {}, entries, commit) catch |err| switch (err) {
                error.WrongExpectedSeq => aegis.assert.never("an append that expects no sequence number never mismatches one"),
                else => |e| return e,
            };
        }

        pub fn appendAllIf(self: *Self, io: Io, expected: Expected, entries: []const Entry, commit: Commit) AppendIfError!Seq {
            return self.appendBatch(io, expected, false, {}, entries, commit);
        }

        fn appendBatch(self: *Self, io: Io, expected: ?Expected, comptime streamed: bool, in: if (streamed) Target else void, entries: []const Entry, commit: Commit) AppendResult(streamed) {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (s.write_failed) return error.PersistenceFailed;
            if (!streamed) try s.expect(expected);
            const run: Run = if (streamed) try self.placeAppend(s, io, in, entries.len) else .{ .head = no_version, .last = no_version };
            if (entries.len == 0) return if (streamed) .{ .seq = s.seq, .version = run.last } else s.seq;
            const last = try values.advance(s.seq, .fromRaw(entries.len));

            // Reserved before anything is written: after the bytes are
            // durable nothing may fail, or the disk would hold records
            // memory does not.
            if (self.keepsRecords(s)) try s.tail.entries.ensureUnusedCapacity(self.gpa, entries.len);

            // Only the records something will read are kept: a journal with
            // no tail and no sink holds one line at a time, however long the
            // batch is.
            var built: std.ArrayList(Built) = .empty;
            defer built.deinit(self.gpa);
            var published = false;
            defer if (!published) for (built.items) |*item| item.release();
            if (self.keepsRecords(s)) try built.ensureTotalCapacityPrecise(self.gpa, entries.len);

            const before = s.seq;
            // An atomic batch names itself in every record it writes, so an
            // open that finds the log ending inside one drops it whole; a
            // batch of one record is whole or absent anyway, and says nothing.
            const batch: ?envelope.Batch = if (commit == .atomic and entries.len > 1)
                .{ .first = try values.successor(before), .last = last }
            else
                null;
            var link = s.log.chainTip();
            const staged_from = s.log.mark();
            for (entries, 0..) |entry, i| {
                const numbered = values.advance(before, .fromRaw(i + 1)) catch aegis.assert.never("the last of them, `last`, was numbered above");
                const place: ?StreamAt = if (streamed) .{ .id = in.stream.bytes, .version = run.head.advance(.fromRaw(i + 1)) catch aegis.assert.never("the last of them, `run.last`, was placed above") } else null;
                var item = self.encode(s, numbered, entry.at, link, entry.event, batch, place) catch |err| {
                    s.unstage(io, staged_from);
                    return err;
                };
                link = item.checksum;
                // A batch is never split across segments: only its first
                // record may start a new one.
                const rotation: Log.Rotation = if (batch != null and i != 0) .stay else .may_rotate;
                {
                    errdefer s.write_failed = true;
                    s.log.stageLine(io, item.bytes, item.at, item.checksum, rotation) catch |err| {
                        item.release();
                        return err;
                    };
                }
                self.noteStaged(s, io, place, numbered, item.bytes.len);
                if (self.keepsRecords(s)) built.appendAssumeCapacity(item) else item.release();
            }

            {
                errdefer s.write_failed = true;
                try s.log.commit(io);
            }
            published = true;

            for (built.items) |*item| {
                _ = self.publish(s, item.*);
            }
            // A batch of records nothing keeps still moved the sequence.
            s.seq = last;
            self.wake(io);
            self.trimTail(s);
            return if (streamed) .{ .seq = last, .version = run.last } else last;
        }

        pub fn reconcile(self: *Self, io: Io) ReconcileError!Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (!s.write_failed) return s.seq;

            const previous = s.seq;
            try s.log.reload(io);
            s.clearTail();
            try self.fillTail(s, io);
            s.write_failed = false;
            try self.caughtUp(s, io, previous);
            return s.seq;
        }

        pub fn nudge(self: *Self, io: Io) void {
            var guard = self.state.acquireUncancelable(io);
            defer guard.deinit(io);
            const s = guard.value();
            s.nudges +%= 1;
            self.wake(io);
        }

        //====================================================================
        // Reading.
        //====================================================================

        /// Copies into `batch`, which stays where it is until its `deinit`:
        /// the records' allocator is its arena.
        pub fn copySince(self: *Self, gpa: Allocator, io: Io, cursor: Seq, batch: *Batch) CopyError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            const window = s.tailSince(cursor);
            batch.* = .{ .records = &.{}, .complete = window.complete, .arena = .init(gpa) };
            errdefer batch.deinit();
            const a = batch.arena.allocator();
            const copied = try a.alloc(Record, window.records.len);
            for (window.records, copied) |owned, *copy| {
                const record = owned.record;
                copy.* = record;
                copy.bytes = try a.dupe(u8, record.bytes);
                copy.event = strand.core.cloneLeaky(a, record.event, .sized(record.bytes.len)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable, // aegis: no-danger: the event was read from these bytes under these bounds, so a copy of it fits them
                };
            }
            batch.records = copied;
        }

        pub fn waitPast(self: *Self, io: Io, cursor: Seq) Io.Cancelable!Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const nudged = guard.value().nudges;
            while (values.atMost(guard.value().seq, cursor) and guard.value().nudges == nudged) {
                // The lock is let go inside this wait and is held again when
                // it returns, on every return, a cancellation included, so
                // the state is read afresh after it and not across it. A
                // `wake` takes the lock first, so it cannot slip in between
                // the check above and the park.
                self.changed.wait(io, &guard, .none) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    // Waits with no timeout and a registry of unlimited size.
                    error.Timeout, error.WaiterLimit => unreachable, // unreachable: `changed` has no limit and `.none` has no deadline
                };
            }
            return guard.value().seq;
        }

        /// Every `waitPast` woken to look again. Called with the lock held, so
        /// that a reader which has checked and not yet parked is not missed:
        /// it parks only by letting the lock go, after registering.
        fn wake(self: *Self, io: Io) void {
            self.changed.broadcast(io);
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
        const Continuity = continuity.State(Header, ReadError, Log.Scan.Boundary);

        pub const Replay = struct {
            journal: *Self,
            /// Copied under the journal lock; reading records observes no
            /// journal state and invokes migration without holding its lock.
            decoder: Decoder,
            scan: Log.Scan,
            /// Holds the record `next` last returned, and nothing else.
            arena: std.heap.ArenaAllocator,
            run: Continuity,
            /// The last record read whole: handed on, or stepped over.
            last: ?Position.Last = null,
            /// Every atomic batch up to here is whole: what the journal held
            /// when the walk was chosen, and the last record of every batch
            /// found whole since. A record of a batch past it is handed on
            /// only once the batch's last record is in the file.
            whole_through: Seq,

            pub fn deinit(walk: *Replay, io: Io) void {
                walk.scan.deinit(io);
                walk.arena.deinit();
                walk.* = undefined;
            }

            pub fn rearmAt(walk: *Replay, io: Io, at: Position) ReplayAtError!void {
                const self = walk.journal;
                if (at.last) |last| {
                    const found = found: {
                        var guard = try self.state.acquire(io);
                        defer guard.deinit(io);
                        const s = guard.value();
                        break :found try s.log.scanAtInto(io, &walk.scan, last.segment, last.start);
                    };
                    if (!found) return error.StalePosition;
                } else {
                    {
                        var guard = try self.state.acquire(io);
                        defer guard.deinit(io);
                        const s = guard.value();
                        try s.log.scanFromInto(io, &walk.scan, at.cursor, .{});
                    }
                }
                walk.whole_through = whole: {
                    var guard = try self.state.acquire(io);
                    defer guard.deinit(io);
                    const s = guard.value();
                    break :whole s.seq;
                };

                walk.run = .{ .cursor = at.cursor };
                walk.last = null;
                _ = walk.arena.reset(.retain_capacity);
                if (at.last) |last| {
                    // Read the named record back before reading its successor.
                    const line = (walk.scan.next(io) catch |err| switch (err) {
                        error.FileNotFound,
                        error.TruncatedRecord,
                        error.RecordTooLarge,
                        error.UnsupportedFormat,
                        => return error.StalePosition,
                        else => |e| return e,
                    }) orelse return error.StalePosition;
                    if (walk.scan.at != 0 or walk.scan.position != last.end) return error.StalePosition;
                    const header = line.parse({}, parseHeader) catch return error.StalePosition;
                    if (header.seq != last.seq or header.c != last.checksum) return error.StalePosition;
                    walk.run.expected = values.following(last.seq);
                    walk.run.link = last.checksum;
                    walk.last = last;
                }
            }

            pub fn next(walk: *Replay, io: Io) ReplayError!?Record {
                while (try walk.scan.next(io)) |line| {
                    if (walk.scan.takeBoundary()) |boundary| try walk.run.beginSegment(boundary);
                    const header = try line.parse({}, parseHeader);
                    if (header.batch) |batch| if (values.below(walk.whole_through, batch.last)) {
                        // A batch being written beside this walk, or one a
                        // crash cut: none of it until all of it is there.
                        if (!try walk.scan.holds(io, batch.last)) {
                            try walk.scan.rewind();
                            return null;
                        }
                        walk.whole_through = batch.last;
                    };
                    // Stepping over a record before its event is parsed is
                    // what lets a reader hold a cursor into a log whose
                    // events it does not know.
                    // A stub keeps its place in the sequence, and is no event.
                    if (!try walk.run.accept(header) or header.removed) {
                        walk.last = walk.lastRead(header);
                        continue;
                    }
                    _ = walk.arena.reset(.retain_capacity);
                    // The envelope has read and checked this line; what is left
                    // is its event, which is the header's span of the same bytes.
                    const record = try recordFrom(walk.decoder, walk.arena.allocator(), header, line.readForParse());
                    walk.last = walk.lastRead(header);
                    return record;
                }
                return null;
            }

            pub fn position(walk: *const Replay) Position {
                const last = walk.last orelse return .{ .cursor = walk.run.cursor };
                return .{ .cursor = values.greater(walk.run.cursor, last.seq), .last = last };
            }

            /// The record just read, where it lies in its file.
            fn lastRead(walk: *const Replay, header: Header) Position.Last {
                return .{
                    .seq = header.seq,
                    .segment = walk.scan.bases[walk.scan.at],
                    .start = walk.scan.line_start,
                    .end = walk.scan.position,
                    .checksum = header.c,
                };
            }
        };

        pub fn replay(self: *Self, io: Io, cursor: Seq, walk: *Replay) ReplayError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return self.replayFrom(s, io, cursor, false, walk);
        }

        /// `replay`, saying whether the walk may build an index it finds
        /// missing. The scan is chosen under the lock `s` is held through,
        /// whether or not it may build an index. The walk is made in `walk`,
        /// which stays where it is until its `deinit`.
        fn replayFrom(self: *Self, s: *State, io: Io, cursor: Seq, may_write: bool, walk: *Replay) ReplayError!void {
            var scan = try s.log.scanFrom(io, cursor, .{ .may_write = may_write });
            errdefer scan.deinit(io);
            walk.* = .{
                .journal = self,
                .decoder = self.captureDecoder(),
                .scan = scan,
                .arena = .init(self.gpa),
                .run = .{ .cursor = cursor },
                .whole_through = s.seq,
            };
        }

        pub fn replayAt(self: *Self, io: Io, position: Position, walk: *Replay) ReplayAtError!void {
            {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                var scan = try s.log.scanIdle();
                errdefer scan.deinit(io);
                walk.* = .{
                    .journal = self,
                    .decoder = self.captureDecoder(),
                    .scan = scan,
                    .arena = .init(self.gpa),
                    .run = .{ .cursor = position.cursor },
                    .whole_through = s.seq,
                };
            }
            errdefer walk.deinit(io);
            try walk.rearmAt(io, position);
        }

        pub fn verify(self: *Self, io: Io) ReplayError!Records {
            var walk: Replay = undefined;
            {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                try self.replayFrom(s, io, s.log.baseSeq(), false, &walk);
            }
            defer walk.deinit(io);
            var seen = values.no_records;
            while (try walk.next(io)) |_| seen = values.plus(seen, .fromRaw(1));
            return seen;
        }

        pub fn lastSeq(self: *Self, io: Io) Io.Cancelable!Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return s.seq;
        }

        pub fn seqAtOrAfter(self: *Self, io: Io, at: Time) SeekError!?Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return s.log.seqAtOrAfter(io, at);
        }

        pub fn refresh(self: *Self, io: Io) OpenError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const previous = s.seq;
            try s.log.reload(io);
            s.clearTail();
            try self.fillTail(s, io);
            try self.caughtUp(s, io, previous);
        }

        pub fn segmentCount(self: *Self, io: Io) Io.Cancelable!usize {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return s.log.segments.items.len;
        }

        pub fn oldestSeq(self: *Self, io: Io) Io.Cancelable!Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return values.following(s.log.baseSeq());
        }

        pub fn openedWith(self: *Self, io: Io) Io.Cancelable!Options {
            // The options are fixed at open, but a call that observes the
            // journal waits its turn at the lock like the others, and is
            // canceled there.
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            return self.config;
        }

        pub const Status = struct {
            /// Whether a persistence operation failed. Writes stay refused
            /// until `reconcile` succeeds; see `AppendError.PersistenceFailed`.
            persistence_failed: bool,
            /// How many unterminated bytes were dropped from the newest
            /// segment during opening or recovery. Zero when none were dropped.
            dropped_bytes: Bytes,
            /// What the records' last sync reached: `flush`, or `.data` on
            /// Linux and Windows for a write into reserved space, and less
            /// where the filesystem declined the call — `.written` from a
            /// network mount on macOS, which declines `F_FULLFSYNC`. Null
            /// before a sync.
            flushed: ?Flush,
        };

        pub fn status(self: *Self, io: Io) Io.Cancelable!Status {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return .{
                .persistence_failed = s.write_failed,
                .dropped_bytes = s.log.dropped_bytes,
                .flushed = s.log.flushed,
            };
        }

        pub const Stats = struct {
            /// How many segment files it is spread over.
            segments: usize,
            /// How many records they hold.
            records: Records,
            /// The bytes of those records, over every segment. The line at
            /// the head of each segment file is not counted, and neither are
            /// the index sidecars, the lock and the snapshot: those are the
            /// framing, a cache and a copy of a fold, not the log.
            bytes: Bytes,
            /// The oldest sequence number still held and the newest. Both are
            /// zero on a log with no records in it.
            oldest_seq: Seq,
            newest_seq: Seq,
        };

        pub fn stats(self: *Self, io: Io) Io.Cancelable!Stats {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            var bytes = values.no_bytes;
            for (s.log.segments.items) |segment| {
                bytes = values.plus(bytes, values.minus(segment.bytes, segment.header_bytes));
            }
            const oldest = values.following(s.log.baseSeq());
            const empty = s.seq == values.beginning or values.below(s.seq, oldest);
            return .{
                .segments = s.log.segments.items.len,
                .records = if (empty) values.no_records else values.span(oldest, s.seq) orelse values.no_records,
                .bytes = bytes,
                .oldest_seq = if (empty) values.beginning else oldest,
                .newest_seq = if (empty) values.beginning else s.seq,
            };
        }

        pub fn subscribe(self: *Self, io: Io, sink: Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, values.beginning);
        }

        pub fn subscribeFrom(self: *Self, io: Io, sink: Sink, cursor: Seq) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, cursor);
        }

        pub fn subscribeAll(self: *Self, io: Io, sinks: []const Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, sinks, values.beginning);
        }

        pub fn subscribeAllFrom(self: *Self, io: Io, sinks: []const Sink, cursor: Seq) SubscribeError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A fold restored to `cursor` needs the record after it. Zero
            // asks for whatever the log holds, which is no promise to miss.
            if (cursor != values.beginning and values.below(cursor, s.log.baseSeq())) return error.HistoryDropped;
            const before = s.sinks.items.len;
            try s.sinks.appendSlice(self.gpa, sinks);
            errdefer s.sinks.shrinkRetainingCapacity(before);
            // The registered copies, not the caller's slice: a sink that is
            // handed records here must be the same sink the next `append`
            // finds, whatever the caller does with its own array.
            const registered = s.sinks.items[before..];

            try self.deliver(s, io, registered, cursor);
        }

        /// Hand `sinks` every record after `cursor` up to the newest: from
        /// the tail where it reaches back that far, from the disk where it
        /// does not.
        fn deliver(self: *Self, s: *State, io: Io, sinks: []const Sink, cursor: Seq) ReplayError!void {
            if (sinks.len == 0 or !values.below(cursor, s.seq)) return;
            var delivered = cursor;
            if (!s.tailSince(cursor).complete) {
                var walk: Replay = undefined;
                try self.replayFrom(s, io, cursor, true, &walk);
                defer walk.deinit(io);
                while (try walk.next(io)) |record| {
                    for (sinks) |sink| sink.f(sink.ctx, record);
                    delivered = record.seq;
                }
            }
            for (s.tailSince(delivered).records) |owned| {
                for (sinks) |sink| sink.f(sink.ctx, owned.record);
            }
        }

        /// After the files were read again: wake every `waitPast` if the
        /// newest record moved, and hand the sinks the records that arrived
        /// after `previous`, so a fold misses none of them.
        fn caughtUp(self: *Self, s: *State, io: Io, previous: Seq) ReplayError!void {
            if (s.seq != previous) self.wake(io);
            try self.deliver(s, io, s.sinks.items, previous);
        }

        pub fn unsubscribe(self: *Self, io: Io, sink: Sink) Io.Cancelable!bool {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            for (s.sinks.items, 0..) |registered, i| {
                if (registered.ctx != sink.ctx or registered.f != sink.f) continue;
                _ = s.sinks.orderedRemove(i);
                return true;
            }
            return false;
        }

        pub const Tailer = struct {
            journal: *Self,
            gpa: Allocator,
            /// This reader's name, owned by the tailer.
            name: []const u8,
            /// Where it has got to. Zero for a name that has never committed
            /// one, and left where it was by a `compact` that dropped past
            /// it — compare it against `oldestSeq` to see what has gone.
            committed: Seq,

            pub fn cursor(tail: *Tailer, io: Io) Io.Cancelable!Seq {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                return tail.committed;
            }

            pub fn deinit(tail: *Tailer) void {
                tail.gpa.free(tail.name);
                tail.* = undefined;
            }

            pub fn replay(tail: *Tailer, io: Io, walk: *Replay) ReplayError!void {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                return self.replayFrom(s, io, tail.committed, false, walk);
            }

            pub fn commit(tail: *Tailer, io: Io, seq: Seq) TailerError!void {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();

                var document: std.Io.Writer.Allocating = .init(self.gpa);
                defer document.deinit();
                json.write(&document.writer, CursorDocument{ .fmt = document_format, .seq = seq.raw() }, .{}) catch
                    return error.OutOfMemory;

                const file = try cursorName(self.gpa, tail.name);
                defer self.gpa.free(file);
                try s.log.writeAtomic(io, file, document.written());
                tail.committed = seq;
            }

            pub fn forget(tail: *Tailer, io: Io) TailerError!void {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                const file = try cursorName(self.gpa, tail.name);
                defer self.gpa.free(file);
                s.log.dir.borrow().deleteFile(io, file) catch |err| switch (err) {
                    error.FileNotFound => return,
                    error.Canceled => return error.Canceled,
                    else => |e| return e,
                };
                try s.log.syncDir(io);
            }
        };

        pub const Reader = struct {
            /// Owned by the `Readers` it came in.
            name: []const u8,
            cursor: Seq,
        };

        /// Only the readers facade hands out access to this state.
        pub const Readers = struct {
            items: []const Reader,
            arena: std.heap.ArenaAllocator,

            pub fn deinit(list: *Readers) void {
                list.arena.deinit();
                list.* = undefined;
            }
        };

        /// Lists into `list`, which stays where it is until its `deinit`:
        /// the names are its arena's.
        pub fn readers(self: *Self, gpa: Allocator, io: Io, list: *Readers) TailerError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();

            list.* = .{ .items = &.{}, .arena = .init(gpa) };
            errdefer list.deinit();
            const a = list.arena.allocator();
            var found: std.ArrayList(Reader) = .empty;

            var iterator = s.log.dir.borrow().iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind == .directory) continue;
                if (!std.mem.endsWith(u8, entry.name, cursor_extension)) continue;
                const name = entry.name[0 .. entry.name.len - cursor_extension.len];
                if (!validTailerName(name)) continue;
                // Forgotten since the listing — by another process, since
                // this one holds the lock: a reader that is gone has nothing
                // left for retention to keep, so it is not listed at zero.
                const cursor = try self.committedCursor(s, io, name) orelse continue;
                try found.append(a, .{ .name = try a.dupe(u8, name), .cursor = cursor });
            }
            list.items = try found.toOwnedSlice(a);
        }

        pub fn minCursor(self: *Self, io: Io) TailerError!?Seq {
            var list: Readers = undefined;
            try self.readers(self.gpa, io, &list);
            defer list.deinit();
            var lowest: ?Seq = null;
            for (list.items) |reader| {
                lowest = if (lowest) |value| values.lesser(value, reader.cursor) else reader.cursor;
            }
            return lowest;
        }

        pub fn tailer(self: *Self, io: Io, name: []const u8, tail: *Tailer) TailerError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            if (!validTailerName(name)) return error.InvalidName;
            const owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned);
            tail.* = .{ .journal = self, .gpa = self.gpa, .name = owned, .committed = try self.readCursor(s, io, owned) };
        }

        /// One path component of lowercase letters, digits, `-` and `_`: the
        /// characters every filesystem this package runs on agrees about, and
        /// none of the ones — a separator, a dot, a colon — that would let a
        /// name reach out of the journal's directory or name a file already
        /// in it. Lowercase only, because the default filesystems of macOS
        /// and Windows fold case: two names that differ only in it would
        /// share one cursor file there.
        fn validTailerName(name: []const u8) bool {
            if (name.len == 0 or name.len > 64) return false;
            for (name) |byte| switch (byte) {
                'a'...'z', '0'...'9', '-', '_' => {},
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
        /// Framing and read bounds have their own errors here; each caller
        /// translates them into its snapshot or cursor contract.
        const DocumentError = Allocator.Error || Io.Cancelable ||
            error{ MalformedDocument, UnsupportedFormat, StreamTooLong };

        fn readDocument(
            s: *State,
            io: Io,
            arena: Allocator,
            Document: type,
            name: []const u8,
            limit: Bytes,
        ) DocumentError!?Document {
            const bytes = aegis.own.readFile(io, s.log.dir.borrow().*, name, arena, limit) catch |err| switch (err) {
                error.FileNotFound => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.StreamTooLong => return error.StreamTooLong,
                else => return error.MalformedDocument,
            };
            const how: json.ParseOptions = .{ .ignore_unknown_fields = true, .limits = .sized(values.limit(limit)) };
            const Versioned = struct { fmt: u32 };
            const version = json.parseLeaky(Versioned, arena, bytes, how) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedDocument,
            };
            if (version.fmt != document_format) return error.UnsupportedFormat;
            return json.parseLeaky(Document, arena, bytes, how) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedDocument,
            };
        }

        /// Where the named reader has got to: zero for a name with no
        /// cursor file, which is a reader that has never committed.
        fn readCursor(self: *Self, s: *State, io: Io, name: []const u8) TailerError!Seq {
            return try self.committedCursor(s, io, name) orelse values.beginning;
        }

        /// The named reader's committed cursor, or null when there is no
        /// cursor file for it.
        fn committedCursor(self: *Self, s: *State, io: Io, name: []const u8) TailerError!?Seq {
            const file = try cursorName(self.gpa, name);
            defer self.gpa.free(file);

            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const Document = struct { seq: u64 };
            // A cursor is a number with a name on it. Nothing this package
            // writes there is longer than this, so nothing longer is read.
            const document = (readDocument(
                s,
                io,
                arena.allocator(),
                Document,
                file,
                .fromRaw(4096),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.UnsupportedFormat => return error.UnsupportedFormat,
                else => return error.CorruptCursor,
            }) orelse return null;
            // Any number is a place to have got to, so this is a position
            // read off a disk and not a record to look up.
            return .fromRaw(document.seq);
        }

        //====================================================================
        // Snapshots and retention.
        //====================================================================

        pub fn snapshot(self: *Self, io: Io, state_bytes: []const u8) SnapshotError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);

            const encoder = std.base64.standard.Encoder;
            const encoded_size = encoder.calcSize(state_bytes.len);
            const framing_size = std.fmt.count(
                "{{\"fmt\":{d},\"seq\":{d},\"state\":\"\"}}",
                .{ document_format, s.seq.raw() },
            );
            const largest = values.limit(self.config.max_snapshot_bytes);
            if (encoded_size > largest or framing_size > largest - encoded_size) {
                return error.SnapshotTooLarge;
            }
            const b64 = try self.gpa.alloc(u8, encoded_size);
            defer self.gpa.free(b64);
            _ = encoder.encode(b64, state_bytes);

            var document: std.Io.Writer.Allocating = .init(self.gpa);
            defer document.deinit();
            json.write(&document.writer, SnapshotDocument{ .fmt = document_format, .seq = s.seq.raw(), .state = b64 }, .{ .limits = .sized(largest) }) catch |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                // Base64 is text, and the document was measured against
                // `largest` above.
                else => unreachable,
            };

            try s.log.syncBeforeSnapshot(io);
            try s.log.writeSnapshot(io, document.written());
        }

        pub fn dropSegmentsBefore(self: *Self, io: Io, seq: Seq) DropError!u64 {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            // The streams whose records go stand past them first, durably, so
            // that none starts again at a version it had.
            try self.raiseFloors(s, io, seq, .whole_segments);
            const dropped = try s.log.dropSegmentsBefore(io, seq);
            if (dropped != 0) s.dropTailBefore(values.following(s.log.baseSeq()));
            return dropped;
        }

        pub fn truncateAfter(self: *Self, io: Io, seq: Seq) TruncateError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (s.write_failed) return error.PersistenceFailed;
            if (values.below(seq, s.seq)) try self.retireSnapshotAfter(s, io, seq);
            try s.log.truncateAfter(io, seq);
            s.clearTail();
            try self.fillTail(s, io);
        }

        /// Remove a snapshot folded from records after `seq`, before they
        /// are cut. The numbers a truncation frees are handed out again, so
        /// such a snapshot would later look current over a history it never
        /// saw. Gone first: a crash before the cut leaves a log with no
        /// snapshot, which replays from the start, never a stale one. A
        /// snapshot that cannot be read is left for `openWithSnapshot` to
        /// report.
        fn retireSnapshotAfter(self: *Self, s: *State, io: Io, seq: Seq) TruncateError!void {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const Document = struct { seq: u64 };
            const document = (readDocument(
                s,
                io,
                arena.allocator(),
                Document,
                Log.snapshot_name,
                self.config.max_snapshot_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return,
            }) orelse return;
            if (values.below(seq, .fromRaw(document.seq))) try s.log.removeSnapshot(io);
        }

        pub fn compact(self: *Self, io: Io, keep_after_seq: Seq) CompactError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (s.write_failed) return error.PersistenceFailed;
            try self.raiseFloors(s, io, keep_after_seq, .every_record);
            try s.log.compact(io, keep_after_seq);
            // The streams' records below their truncation points become
            // stubs: their events leave the files.
            try self.redactTruncated(s, io);
            s.clearTail();
            try self.fillTail(s, io);
        }

        pub fn backup(self: *Self, io: Io, dest: []const u8) BackupError!Seq {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            if (self.config.access == .read) {
                // A reader's segment inventory is a snapshot from its last
                // open or refresh. Backup begins with a current directory
                // view so rotations completed before this call are included.
                try s.log.reload(io);
                s.clearTail();
                try self.fillTail(s, io);
            }
            return s.log.backup(io, dest);
        }

        //====================================================================
        // Internals.
        //====================================================================

        /// A record serialised and waiting to be written.
        ///
        /// `record` is there when something will read it: an arena owns every
        /// slice of it. A tail or sink takes ownership after the write; a
        /// round-trip check alone releases it as soon as it has been staged.
        /// When nothing will — no tail, no sink, no round-trip check —
        /// the line is the only thing built, and it is the journal's `line`:
        /// valid until the next record is encoded, which is after this one
        /// has been handed to the log.
        const Built = struct {
            arena: ?*std.heap.ArenaAllocator,
            bytes: []const u8,
            seq: Seq,
            at: Time,
            /// This record's checksum, which the next one links back to.
            checksum: u32,
            record: ?Record,

            fn release(built: *Built) void {
                if (built.arena) |arena| destroyArena(arena);
            }
        };

        /// Whether a record needs an owner after the write, for the cache or
        /// for callbacks. Verification alone reads it before the write.
        fn keepsRecords(self: *const Self, s: *State) bool {
            return self.config.tail_records != values.no_records or s.sinks.items.len != 0;
        }

        /// Whether encoding must parse its result, for a reader or a check.
        fn needsRecord(self: *const Self, s: *State) bool {
            return self.keepsRecords(s) or self.config.verify_round_trip;
        }

        /// What writing a record's value refused, as an append says it: the
        /// buffer's own failure, a value past the record bound, or a value
        /// the format cannot write.
        fn refused(encoding: *const Encoding, err: anyerror) AppendError {
            return switch (err) {
                error.WriteFailed => switch (encoding.diagnose(error.WriteFailed)) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.WriteFailed => error.NotRoundTrippable,
                },
                error.OutOfMemory => error.OutOfMemory,
                error.OutputLimit, error.LengthLimit, error.ItemLimit, error.WorkLimit, error.AllocationLimit => error.RecordTooLarge,
                else => error.NotRoundTrippable,
            };
        }

        /// The record's line written into `encoding` as strand writes a
        /// `Line`, null optionals included, and left open: the checksum is
        /// its last member. Its shape is the one for what the record is in:
        /// a batch, a stream, both or neither.
        fn openLine(self: *const Self, encoding: *Encoding, seq: Seq, at: Time, back_link: u32, event: Event, batch: ?envelope.Batch, place: ?StreamAt) AppendError!json.OpenObject {
            const out = &encoding.output;
            const value_options: json.WriteOptions = .{ .limits = .sized(values.limit(self.config.max_record_bytes)) };
            const v = self.config.schema_version;
            return (if (batch) |b| (if (place) |in| json.writeObjectOpen(&out.writer, LineInStreamBatch{
                .seq = seq.raw(),
                .at = at.raw(),
                .v = v,
                .p = back_link,
                .bf = b.first.raw(),
                .bl = b.last.raw(),
                .s = in.id,
                .sv = in.version.raw(),
                .ev = event,
            }, value_options) else json.writeObjectOpen(&out.writer, LineInBatch{
                .seq = seq.raw(),
                .at = at.raw(),
                .v = v,
                .p = back_link,
                .bf = b.first.raw(),
                .bl = b.last.raw(),
                .ev = event,
            }, value_options)) else if (place) |in| json.writeObjectOpen(&out.writer, LineInStream{
                .seq = seq.raw(),
                .at = at.raw(),
                .v = v,
                .p = back_link,
                .s = in.id,
                .sv = in.version.raw(),
                .ev = event,
            }, value_options) else json.writeObjectOpen(&out.writer, Line{
                .seq = seq.raw(),
                .at = at.raw(),
                .v = v,
                .p = back_link,
                .ev = event,
            }, value_options)) catch |err| return refused(encoding, err);
        }

        /// Serialise one record.
        ///
        /// Where something will read the record back — a tail, a sink, or the
        /// round-trip check asked for — it is parsed back out of the bytes
        /// that will be written, so what memory holds is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append. Where nothing will, that parse would build a record
        /// and drop it unread, so it is not done.
        fn encode(self: *Self, s: *State, seq: Seq, at: Time, back_link: u32, event: Event, batch: ?envelope.Batch, place: ?StreamAt) AppendError!Built {
            // A record numbered outside what a reader accepts would be durable
            // before anything noticed, so these hold in every build.
            aegis.assert.pre(seq != values.beginning, "a record is numbered from one");
            aegis.assert.pre(values.atMost(seq, values.newest_possible), "a record is numbered no higher than an i64");
            if (batch) |bounds| {
                aegis.assert.pre(values.atMost(bounds.first, seq), "a batch starts at or before its record");
                aegis.assert.pre(values.atMost(seq, bounds.last), "a batch ends at or after its record");
            }
            const needs_record = self.needsRecord(s);
            const arena: ?*std.heap.ArenaAllocator = if (needs_record) try createArena(self.gpa) else null;
            errdefer if (arena) |a| destroyArena(a);

            // The bytes are the ones strand writes for a `Line`, written into
            // the one buffer that becomes the stored bytes; the suite's golden
            // lines and its property over every shape hold it to that.
            //
            // A record something keeps is written into its own arena, sized
            // from the last record so a run of records alike is written
            // without growing the buffer. One nothing keeps is written into
            // the journal's `line`, which it hands back grown or not.
            var encoding: Encoding = .init(if (arena) |a| .init(a.allocator()) else .fromArrayList(self.gpa, &s.line));
            const out = &encoding.output;
            defer if (!needs_record) {
                s.line = out.toArrayList();
            };
            if (needs_record) {
                out.ensureTotalCapacityPrecise(s.record_hint + 32) catch return error.OutOfMemory;
            } else {
                out.clearRetainingCapacity();
            }
            var record = try self.openLine(&encoding, seq, at, back_link, event, batch, place);
            // The checksum covers everything the record says except the
            // checksum itself: the object so far, before `,"c":<crc>}` closes
            // it.
            const sum = checksum(out.written());
            record.member("c", sum) catch return error.OutOfMemory;
            record.close() catch return error.OutOfMemory;
            // The bound counts the exact stored line, the checksum's digits
            // included, before any file write.
            if (out.written().len > values.limit(self.config.max_record_bytes)) return error.RecordTooLarge;

            if (!needs_record) {
                const stored = out.written();
                return .{
                    .arena = null,
                    .bytes = stored,
                    .seq = seq,
                    .at = at,
                    .checksum = sum,
                    .record = null,
                };
            }

            const stored = out.toOwnedSlice() catch return error.OutOfMemory;
            s.record_hint = stored.len;
            // The event is read back out of the bytes that will be written,
            // found by the envelope reader every replay uses, and parsed
            // exactly as every read parses it, so an event a read would
            // refuse is refused here, before it reaches the disk.
            const fields = envelope.read({}, stored) catch return error.NotRoundTrippable;
            const span = (fields.head() catch return error.NotRoundTrippable).ev;
            const parsed = json.parseLeaky(
                Event,
                arena.?.allocator(),
                stored[span.from..span.to],
                eventParse(stored.len),
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
                    .version = self.config.schema_version,
                    // The id the record carries is the one in its own bytes.
                    .stream = if (place) |in| .{ .id = idIn(stored, in.id), .version = in.version } else null,
                    .event = parsed,
                    .bytes = stored,
                },
            };
        }

        /// Take a record the disk now holds into the tail and hand it to every
        /// sink, and report whether the tail took ownership of its arena.
        ///
        /// Nothing here may fail: the capacity was reserved before the write,
        /// because the disk must never hold a record memory does not.
        fn publish(self: *Self, s: *State, item: Built) bool {
            s.seq = item.seq;
            if (!self.keepsRecords(s)) return false;
            const record = item.record.?;
            s.tail.appendAssumeCapacity(.{ .record = record, .arena = item.arena.? });
            for (s.sinks.items) |sink| sink.f(sink.ctx, record);
            return true;
        }

        /// Read the newest records back into the tail, and check that they say
        /// what the segment names say.
        fn fillTail(self: *Self, s: *State, io: Io) OpenError!void {
            s.seq = s.log.lastSeq();
            var rebuilt: Tail = .{};
            errdefer rebuilt.deinit(self.gpa);
            const from = values.back(s.seq, self.config.tail_records) orelse s.log.baseSeq();

            var scan = try s.log.scanFrom(io, from, .{ .may_write = true, .extent = .known });
            defer scan.deinit(io);

            var run: Continuity = .{ .cursor = from };
            while (try scan.next(io)) |line| {
                if (scan.takeBoundary()) |boundary| try run.beginSegment(boundary);
                const header = try line.parse({}, parseHeader);
                if (!try run.accept(header) or header.removed) continue;

                const arena = try createArena(self.gpa);
                errdefer destroyArena(arena);
                const stored = try arena.allocator().dupe(u8, line.readForParse());
                const record = try recordFrom(self.captureDecoder(), arena.allocator(), header, stored);
                try rebuilt.entries.ensureUnusedCapacity(self.gpa, 1);
                rebuilt.appendAssumeCapacity(.{ .record = record, .arena = arena });
                rebuilt.trim(self.config);
            }

            // Continuity belongs to the walk, not the cache: either tail
            // ceiling may evict even the newest record while it is read.
            if (run.expected) |next| {
                if (next != values.following(s.seq)) return error.DiscontinuousSeq;
            } else if (s.log.baseSeq() != s.seq) {
                return error.DiscontinuousSeq;
            }
            // Before the tail is taken: a failure here leaves the old one.
            try self.rescanStreams(s, io);
            s.tail.deinit(self.gpa);
            s.tail = rebuilt;
        }

        //====================================================================
        // Streams.
        //====================================================================

        /// What an append into a stream expects the stream to hold.
        pub const StreamExpected = union(enum) {
            /// Whatever it holds.
            any,
            /// No record: the stream is new.
            no_stream,
            /// At least one record.
            exists,
            /// Exactly this many: its newest record is this version.
            exact: StreamVersion,
        };

        /// Where an append into a stream put its record, or the last of its
        /// batch.
        pub const Appended = struct {
            seq: Seq,
            version: StreamVersion,
        };

        pub const StreamAppendError = AppendError || OpenError || error{ WrongExpectedVersion, StreamVersionExhausted };

        pub const StreamReadError = OpenError || error{StreamCompacted};

        pub const TruncateStreamError = OpenError || Log.WriteFileError || error{ ReadOnly, PersistenceFailed, StreamCompacted };

        const Target = struct { stream: Stream, expected: StreamExpected };

        /// The name of the file that keeps each truncated stream's point, in
        /// the journal's directory.
        pub const truncations_name = Log.truncations_name;

        /// Append `event` to `stream`, if the stream holds what `expected`
        /// says, as its next version: one durable write, as `append`.
        /// `error.WrongExpectedVersion` when it does not, and nothing is
        /// written; `streamVersion` reads what it holds.
        pub fn appendTo(self: *Self, io: Io, stream: Stream, expected: StreamExpected, at: Time, event: Event) StreamAppendError!Appended {
            return self.appendOne(io, null, true, .{ .stream = stream, .expected = expected }, at, event, .now);
        }

        /// Append `entries` to `stream` as its next versions, one batch, if
        /// the stream holds what `expected` says. Every record of the batch
        /// is in `stream`. Returns where the last went.
        pub fn appendAllTo(self: *Self, io: Io, stream: Stream, expected: StreamExpected, entries: []const Entry, commit: Commit) StreamAppendError!Appended {
            return self.appendBatch(io, null, true, .{ .stream = stream, .expected = expected }, entries, commit);
        }

        /// The version of `stream`'s newest record, or `no_version` for a
        /// stream with none. A stream truncated past all its records stands
        /// at the version before its truncation point.
        pub fn streamVersion(self: *Self, io: Io, stream: Stream) OpenError!StreamVersion {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            return self.streamHead(guard.value(), io, stream.bytes);
        }

        /// Make `stream`'s records below version `before` unreadable now:
        /// `readStream` starts at `before`, and one asked to start below it
        /// is `error.StreamCompacted`. The next `compact` removes their
        /// events from the files. A point at or below the stream's current
        /// one changes nothing. Durable when it returns.
        pub fn truncateStreamBefore(self: *Self, io: Io, stream: Stream, before: StreamVersion) TruncateStreamError!void {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (s.write_failed) return error.PersistenceFailed;
            const now = s.streams.truncation(stream.bytes);
            if (!(now.compare(before) == .lt)) return;
            // The head stays where it is: truncating removes records, not the
            // stream's place.
            const head = try self.streamHead(s, io, stream.bytes);
            try s.streams.setTruncation(stream.bytes, before);
            self.writeTruncations(s, io) catch |err| {
                s.streams.restoreTruncation(stream.bytes, now);
                return err;
            };
            s.streams.heads.put(stream.bytes, .{ .version = head });
        }

        /// The records of one stream, oldest first, from a version on.
        pub const StreamRead = struct {
            journal: *Self,
            decoder: Decoder,
            /// Where each record to read is, chosen when the read began.
            places: std.ArrayList(Place),
            next_place: usize,
            /// Holds the record `next` last returned, and nothing else.
            arena: std.heap.ArenaAllocator,
            /// The stream, copied.
            id: [streams.max_id_bytes]u8 = undefined,
            id_len: u8 = 0,

            const Place = struct { segment: Seq, offset: Bytes, version: StreamVersion };

            pub fn deinit(walk: *StreamRead) void {
                walk.places.deinit(walk.journal.gpa);
                walk.arena.deinit();
                walk.* = undefined;
            }

            /// The next record, or null when the records the stream held
            /// when the read began are done. A record the journal no longer
            /// holds (dropped, compacted, truncated since) is stepped over.
            pub fn next(walk: *StreamRead, io: Io) StreamReadError!?Record {
                const self = walk.journal;
                while (walk.next_place < walk.places.items.len) {
                    const place = walk.places.items[walk.next_place];
                    walk.next_place += 1;
                    const line = line: {
                        var guard = try self.state.acquire(io);
                        defer guard.deinit(io);
                        const s = guard.value();
                        if (place.version.compare(s.streams.truncation(walk.streamId())) == .lt) continue;
                        break :line try s.log.lineOf(io, place.segment, place.offset) orelse continue;
                    };
                    defer self.gpa.free(line);
                    const header = parseHeader({}, line) catch |err| switch (err) {
                        // A record rewritten or gone since the read began.
                        error.CorruptRecord, error.ChecksumMismatch => continue,
                    };
                    const in = header.in_stream orelse continue;
                    if (header.removed or in.version != place.version) continue;
                    _ = walk.arena.reset(.retain_capacity);
                    const stored = try walk.arena.allocator().dupe(u8, line);
                    return try recordFrom(walk.decoder, walk.arena.allocator(), header, stored);
                }
                return null;
            }

            fn streamId(walk: *const StreamRead) []const u8 {
                return walk.id[0..walk.id_len];
            }
        };

        /// Read `stream` from version `from` on, into `walk`, which is the
        /// caller's to `deinit`. `no_version` reads from its oldest readable
        /// record. A `from` below the stream's truncation point, or below
        /// the records compaction and dropped segments have left, is
        /// `error.StreamCompacted`. The read takes the records the stream
        /// holds now; one appended after it is not among them.
        pub fn readStream(self: *Self, io: Io, stream: Stream, from: StreamVersion, walk: *StreamRead) StreamReadError!void {
            walk.* = .{
                .journal = self,
                .decoder = self.captureDecoder(),
                .places = .empty,
                .next_place = 0,
                .arena = .init(self.gpa),
            };
            errdefer walk.deinit();
            @memcpy(walk.id[0..stream.bytes.len], stream.bytes);
            walk.id_len = @intCast(stream.bytes.len);

            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            try self.freshStreams(s, io);
            const floor = s.streams.truncation(stream.bytes);
            if (from != no_version and (from.compare(floor) == .lt)) return error.StreamCompacted;
            const start = if ((from.compare(floor) == .lt)) floor else from;

            const segments = s.log.segments.items;
            if (segments.len == 0) return;
            for (segments[0 .. segments.len - 1]) |segment| {
                const index = try self.streamIndex(s, io, segment) orelse continue;
                defer index.deinit(self.gpa);
                const section = index.find(stream.bytes) orelse continue;
                for (0..section.len()) |i| {
                    const entry = section.at(i);
                    if ((entry.version.compare(start) == .lt)) continue;
                    try walk.places.append(self.gpa, .{ .segment = segment.base_seq, .offset = entry.offset, .version = entry.version });
                }
            }
            for (s.streams.placed.items) |p| {
                if (!std.mem.eql(u8, p.id, stream.bytes) or (p.entry.version.compare(start) == .lt)) continue;
                try walk.places.append(self.gpa, .{ .segment = s.streams.active_base, .offset = p.entry.offset, .version = p.entry.version });
            }
            // What compaction or a dropped segment took is below the first
            // record found; a `from` there is not readable.
            if (from != no_version and walk.places.items.len > 0 and (from.compare(walk.places.items[0].version) == .lt))
                return error.StreamCompacted;
        }

        /// The newest version of stream `id`: the active segment's, else the
        /// heads', else the newest sealed segment's whose index holds it,
        /// and never below its truncation point's predecessor.
        fn streamHead(self: *Self, s: *State, io: Io, id: []const u8) OpenError!StreamVersion {
            try self.freshStreams(s, io);
            const book = &s.streams;
            const found = found: {
                if (book.activeVersion(id)) |v| break :found v;
                if (book.heads.get(id)) |head| break :found head.version;
                const segments = s.log.segments.items;
                var v = no_version;
                if (segments.len > 1) {
                    var i = segments.len - 1;
                    while (i > 0) {
                        i -= 1;
                        const segment = segments[i];
                        const index = try self.streamIndex(s, io, segment) orelse continue;
                        defer index.deinit(self.gpa);
                        if (index.find(id)) |section| {
                            v = section.last().version;
                            break;
                        }
                    }
                }
                book.heads.put(id, .{ .version = v });
                break :found v;
            };
            // A stream truncated before `floor` stands at least just below
            // it; one never truncated has no floor, and no version before it.
            const below_floor = book.truncation(id).predecessor() catch return found;
            return if (found.compare(below_floor) == .lt) below_floor else found;
        }

        /// The versions an append of `count` records into `in` takes: those
        /// after `head`, up to `last`.
        const Run = struct { head: StreamVersion, last: StreamVersion };

        /// Where an append of `count` records into `in` goes, once the
        /// stream is what `in.expected` says.
        fn placeAppend(self: *Self, s: *State, io: Io, in: Target, count: usize) StreamAppendError!Run {
            const head = try self.streamHead(s, io, in.stream.bytes);
            switch (in.expected) {
                .any => {},
                .no_stream => if (head != no_version) return error.WrongExpectedVersion,
                .exists => if (head == no_version) return error.WrongExpectedVersion,
                .exact => |v| if (head != v) return error.WrongExpectedVersion,
            }
            const last = head.advance(.fromRaw(count)) catch return error.StreamVersionExhausted;
            if (last.compare(streams.last_version) == .gt) return error.StreamVersionExhausted;
            return .{ .head = head, .last = last };
        }

        /// Note a record just staged: a stream's record joins the active
        /// segment's, and a segment the log has just sealed gets its stream
        /// index. Never fails: what cannot be noted leaves the book stale,
        /// and the next lookup reads the active segment again.
        fn noteStaged(self: *Self, s: *State, io: Io, place: ?StreamAt, seq: Seq, line_len: usize) void {
            const book = &s.streams;
            const segments = s.log.segments.items;
            if (segments.len == 0) {
                book.stale = true;
                return;
            }
            const active = segments[segments.len - 1];
            if (!book.stale and active.base_seq != book.active_base) self.sealStreams(s, io);
            if (book.stale) return;
            const in = place orelse return;
            const offset = active.bytes.sub(.fromRaw(line_len + 1)) catch {
                book.stale = true;
                return;
            };
            book.place(in.id, .{ .version = in.version, .seq = seq, .offset = offset }) catch {
                book.stale = true;
            };
        }

        /// The active segment the book describes has been sealed: write its
        /// stream index, keep its heads, and start on the new one.
        fn sealStreams(self: *Self, s: *State, io: Io) void {
            const book = &s.streams;
            for (book.placed.items) |p| book.heads.put(p.id, .{ .version = p.entry.version });
            if (self.config.access == .write) for (s.log.segments.items) |segment| {
                if (segment.base_seq != book.active_base) continue;
                self.writeStreamIndex(s, io, segment, book.placed.items) catch |err| {
                    // A cache: a lookup that finds none builds it.
                    std.log.debug("optional stream index maintenance: {t}", .{err});
                };
            };
            const segments = s.log.segments.items;
            book.resetActive(segments[segments.len - 1].base_seq);
        }

        fn writeStreamIndex(self: *Self, s: *State, io: Io, segment: Log.Segment, placed: []const streams.Placed) (Allocator.Error || Io.Dir.WriteFileError)!void {
            const buf = &s.streams.buf;
            try streams.encode(self.gpa, segment.base_seq, segment.bytes, placed, buf);
            const name = Log.segmentName(Log.stream_index_extension, segment.base_seq);
            try s.log.dir.borrow().writeFile(io, .{ .sub_path = &name, .data = buf.items });
        }

        /// Segment `segment`'s stream index, read whole and owned by the
        /// caller (`deinit`): the one beside it when it describes the
        /// segment's bytes, else one built from the segment (and written
        /// beside it, when the journal writes). Null for a segment holding
        /// no stream's record.
        fn streamIndex(self: *Self, s: *State, io: Io, segment: Log.Segment) OpenError!?streams.Index {
            const of: streams.Index.Of = .{ .base_seq = segment.base_seq, .bytes = segment.bytes };
            const name = Log.segmentName(Log.stream_index_extension, segment.base_seq);
            // An index is never longer than its segment and a header: each
            // record it places took more bytes in the segment than its
            // entry does. A longer file is not its index.
            const limit = segment.bytes.add(.fromRaw(4096)) catch values.furthest;
            if (aegis.own.readFile(io, s.log.dir.borrow().*, &name, self.gpa, limit)) |bytes| {
                if (streams.Index.parse(.init(bytes), of)) |index| {
                    if (index.streams == 0) {
                        self.gpa.free(bytes);
                        return null;
                    }
                    return index;
                } else |_| self.gpa.free(bytes);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {},
            }

            // Built from the segment: each line's place in its stream.
            var ids: std.heap.ArenaAllocator = .init(self.gpa);
            defer ids.deinit();
            var placed: std.ArrayList(streams.Placed) = .empty;
            defer placed.deinit(self.gpa);
            var scan = try s.log.scanIdle();
            defer scan.deinit(io);
            if (try s.log.scanAtInto(io, &scan, segment.base_seq, values.no_bytes)) {
                while (try scan.next(io)) |line| {
                    if (scan.bases[scan.at] != segment.base_seq) break;
                    const header = try line.parse({}, parseHeader);
                    const in = header.in_stream orelse continue;
                    const bytes = line.readForParse();
                    try placed.append(self.gpa, .{
                        .id = try ids.allocator().dupe(u8, bytes[in.id.from..in.id.to]),
                        .entry = .{ .version = in.version, .seq = header.seq, .offset = scan.line_start },
                    });
                }
            }
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            try streams.encode(self.gpa, segment.base_seq, segment.bytes, placed.items, &out);
            const bytes = try out.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(bytes);
            // A segment that gives a stream's versions out of order is not
            // one this journal wrote: no index of it would be read.
            const index = streams.Index.parse(.init(bytes), of) catch return error.CorruptRecord;
            if (self.config.access == .write) s.log.dir.borrow().writeFile(io, .{ .sub_path = &name, .data = bytes }) catch |err| {
                std.log.debug("optional stream index maintenance: {t}", .{err});
            };
            if (placed.items.len == 0) {
                index.deinit(self.gpa);
                return null;
            }
            return index;
        }

        /// Read the active segment's records in streams again, if the book
        /// may not describe them.
        fn freshStreams(self: *Self, s: *State, io: Io) OpenError!void {
            if (!s.streams.stale) return;
            try self.rescanStreams(s, io);
        }

        /// The book from the files: the active segment's streams read again,
        /// and no head kept, since what the segments hold may have changed.
        fn rescanStreams(self: *Self, s: *State, io: Io) OpenError!void {
            _ = self;
            const book = &s.streams;
            book.heads.clear();
            book.stale = true;
            const segments = s.log.segments.items;
            if (segments.len == 0) {
                book.resetActive(values.beginning);
                return;
            }
            const active = segments[segments.len - 1];
            book.resetActive(active.base_seq);
            errdefer book.stale = true;
            var scan = try s.log.scanIdle();
            defer scan.deinit(io);
            if (!try s.log.scanAtInto(io, &scan, active.base_seq, values.no_bytes)) return;
            while (try scan.next(io)) |line| {
                const header = try line.parse({}, parseHeader);
                const in = header.in_stream orelse continue;
                const bytes = line.readForParse();
                try book.place(bytes[in.id.from..in.id.to], .{ .version = in.version, .seq = header.seq, .offset = scan.line_start });
            }
        }

        /// Which records a cut at a sequence number removes: every one at or
        /// before it (`compact`), or those of the segments wholly at or
        /// before it (`dropSegmentsBefore`).
        const Cut = enum { every_record, whole_segments };

        /// Raise the truncation point of each stream with records a cut at
        /// `cut` removes past the newest of them, and write the points
        /// before the cut is made: a stream whose records are all gone keeps
        /// its version, and a read below what is left is
        /// `error.StreamCompacted` rather than a gap.
        fn raiseFloors(self: *Self, s: *State, io: Io, cut: Seq, which: Cut) (OpenError || Log.WriteFileError)!void {
            if (self.config.access == .read) return;
            try self.freshStreams(s, io);
            var ids: std.heap.ArenaAllocator = .init(self.gpa);
            defer ids.deinit();
            var newest: std.StringHashMapUnmanaged(StreamVersion) = .empty;
            defer newest.deinit(self.gpa);
            const segments = s.log.segments.items;
            if (segments.len == 0) return;
            for (segments[0 .. segments.len - 1]) |segment| {
                if (segment.base_seq.compare(cut) == .gt) break;
                if (which == .whole_segments and segment.last_seq.compare(cut) == .gt) break;
                const index = try self.streamIndex(s, io, segment) orelse continue;
                defer index.deinit(self.gpa);
                var it = index.iterator();
                while (it.next()) |section| {
                    var top = no_version;
                    for (0..section.len()) |i| {
                        const entry = section.at(i);
                        if (entry.seq.compare(cut) != .gt) top = entry.version;
                    }
                    if (top != no_version) try keepNewest(self.gpa, &ids, &newest, section.id, top);
                }
            }
            if (which == .every_record) for (s.streams.placed.items) |p| {
                if (p.entry.seq.compare(cut) != .gt) try keepNewest(self.gpa, &ids, &newest, p.id, p.entry.version);
            };
            var changed = false;
            var it = newest.iterator();
            while (it.next()) |found| {
                const past = found.value_ptr.successor() catch aegis.assert.never("a version read is at most `last_version`");
                if (s.streams.truncation(found.key_ptr.*).compare(past) != .lt) continue;
                try s.streams.setTruncation(found.key_ptr.*, past);
                changed = true;
            }
            if (changed) try self.writeTruncations(s, io);
        }

        fn keepNewest(gpa: Allocator, ids: *std.heap.ArenaAllocator, newest: *std.StringHashMapUnmanaged(StreamVersion), id: []const u8, version: StreamVersion) Allocator.Error!void {
            const slot = try newest.getOrPut(gpa, id);
            if (!slot.found_existing) {
                slot.key_ptr.* = try ids.allocator().dupe(u8, id);
                slot.value_ptr.* = version;
            } else if (slot.value_ptr.compare(version) == .lt) slot.value_ptr.* = version;
        }

        /// Rewrite every segment holding a record below its stream's
        /// truncation point, with that record's stub in its place: the
        /// event leaves the files, the record's place in the sequence and
        /// in its stream stays, and so does every checksum after it. The
        /// active segment is sealed first when it holds one.
        fn redactTruncated(self: *Self, s: *State, io: Io) (OpenError || Log.CompactError)!void {
            if (s.streams.truncations.count() == 0) return;
            try self.freshStreams(s, io);
            var active_holds = false;
            for (s.streams.placed.items) |p| {
                if (p.entry.version.compare(s.streams.truncation(p.id)) == .lt) active_holds = true;
            }
            if (active_holds) {
                try s.log.sealActive(io);
                // A record now names the new active segment: the book is
                // read again when it is next asked.
                s.streams.stale = true;
            }
            var rewrote = false;
            var i: usize = 0;
            while (i + 1 < s.log.segments.items.len) : (i += 1) {
                const segment = s.log.segments.items[i];
                if (!try self.holdsTruncated(s, io, segment)) continue;
                if (try s.log.redactSegment(io, segment.base_seq, s, stubOf)) rewrote = true;
            }
            if (rewrote) try s.log.reload(io);
        }

        /// Whether `segment`'s stream index has a record below its stream's
        /// truncation point that is not a stub already.
        fn holdsTruncated(self: *Self, s: *State, io: Io, segment: Log.Segment) OpenError!bool {
            const index = try self.streamIndex(s, io, segment) orelse return false;
            defer index.deinit(self.gpa);
            var points = s.streams.truncations.iterator();
            while (points.next()) |point| {
                const section = index.find(point.key_ptr.*) orelse continue;
                if (section.at(0).version.compare(point.value_ptr.*) == .lt) return true;
            }
            return false;
        }

        /// The stub of a record below its stream's truncation point, into
        /// `out`: `seq`, `at`, `v`, `p`, the batch it was in, `s`, `sv`,
        /// then `"x":1`, `sc` (the checksum of all before it) and the
        /// record's own `c`, which the record after it links back to.
        fn stubOf(s: *State, line: []const u8, out: *std.ArrayList(u8)) error{ OutOfMemory, CorruptRecord }!bool {
            const header = parseHeader({}, line) catch return error.CorruptRecord;
            if (header.removed) return false;
            const in = header.in_stream orelse return false;
            const id = line[in.id.from..in.id.to];
            if (in.version.compare(s.streams.truncation(id)) != .lt) return false;
            const gpa = s.streams.gpa;
            var w: std.Io.Writer.Allocating = .fromArrayList(gpa, out);
            defer out.* = w.toArrayList();
            w.writer.print("{{\"seq\":{d},\"at\":{d},\"v\":{d},\"p\":{d}", .{ header.seq.raw(), header.at.raw(), header.version, header.p }) catch return error.OutOfMemory;
            if (header.batch) |b| w.writer.print(",\"bf\":{d},\"bl\":{d}", .{ b.first.raw(), b.last.raw() }) catch return error.OutOfMemory;
            w.writer.print(",\"s\":\"{s}\",\"sv\":{d},\"x\":1", .{ id, in.version.raw() }) catch return error.OutOfMemory;
            const sc = checksum(w.written());
            w.writer.print(",\"sc\":{d},\"c\":{d}}}", .{ sc, header.c }) catch return error.OutOfMemory;
            return true;
        }

        /// Each truncated stream's point, from the file that keeps them.
        fn loadTruncations(self: *Self, s: *State, io: Io) OpenError!void {
            s.streams.clearTruncations();
            // As long as the streams truncated are many: the journal's own
            // file, held whole in memory once read, as the book holds it.
            const bytes = aegis.own.readFile(io, s.log.dir.borrow().*, truncations_name, self.gpa, values.furthest) catch |err| switch (err) {
                error.FileNotFound => return,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return error.CorruptRecord,
            };
            defer self.gpa.free(bytes);
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const point = parseTruncation(line) orelse return error.CorruptRecord;
                try s.streams.setTruncation(point.id, point.before);
            }
        }

        const Truncation = struct { id: []const u8, before: StreamVersion };

        /// One line of the truncations file: `{"s":"<id>","tb":<version>}`.
        fn parseTruncation(line: []const u8) ?Truncation {
            var members: json.Members = undefined;
            members.init(line, .{ .limits = .sized(line.len) });
            var id: ?streams.Stream = null;
            var before: ?u64 = null;
            while (members.next() catch return null) |member| {
                if (member.is("s")) {
                    if (id != null) return null;
                    id = streams.idOf(member.value) orelse return null;
                } else if (member.is("tb")) {
                    if (before != null) return null;
                    before = envelope.integerOf(u64, member.value) orelse return null;
                }
            }
            _ = members.finish() catch return null;
            return .{ .id = (id orelse return null).bytes, .before = .fromRaw(before orelse return null) };
        }

        /// Every truncation point, written whole and atomically.
        fn writeTruncations(self: *Self, s: *State, io: Io) (Allocator.Error || Log.WriteFileError)!void {
            var out: std.Io.Writer.Allocating = .init(self.gpa);
            defer out.deinit();
            var it = s.streams.truncations.iterator();
            while (it.next()) |point| {
                out.writer.print("{{\"s\":\"{s}\",\"tb\":{d}}}\n", .{ point.key_ptr.*, point.value_ptr.raw() }) catch return error.OutOfMemory;
            }
            try s.log.writeAtomic(io, truncations_name, out.written());
        }

        /// Drop the oldest records until the tail is inside both of its
        /// ceilings — at least half of it at a time, so that keeping a tail
        /// costs a constant amount per append rather than a growing one.
        fn trimTail(self: *Self, s: *State) void {
            s.tail.trim(self.config);
        }

        /// Everything in a line except the event: what a reader needs to decide
        /// whether the event is worth parsing at all.
        const Header = struct {
            seq: Seq,
            at: Time,
            version: u32,
            /// The checksum of the record before this one.
            p: u32,
            /// This record's own checksum, which the next one carries as its
            /// `p`.
            c: u32,
            /// The atomic batch the record was written in, if it was.
            batch: ?envelope.Batch,
            /// Its stream: where the id sits in the line, and its version.
            in_stream: ?InStream,
            /// A stub: a stream's record removed past its truncation, which
            /// keeps its place and has no event.
            removed: bool,
            /// Where the event sits in the line, still unparsed.
            ev: Span,
        };

        const InStream = struct { id: Span, version: StreamVersion };

        const Span = envelope.Span;

        /// A line's envelope, read through its members (`envelope.read`),
        /// and its checksum checked.
        fn parseHeader(_: void, line: []const u8) HeaderError!Header {
            const fields = envelope.read({}, line) catch return error.CorruptRecord;
            // A line that does not end in a checksum is not a record and
            // there is nothing to check it against.
            const t = fields.trailer orelse return error.CorruptRecord;
            if (checksum(t.covered) != t.sum) return error.ChecksumMismatch;
            const head = fields.head() catch return error.CorruptRecord;
            // The id kept as where it sits, so a record built from a copy of
            // the line takes it from the copy.
            const in_stream: ?InStream = if (head.in_stream) |place| .{ .id = place.id, .version = place.version } else null;
            return .{ .seq = head.seq, .at = head.at, .version = head.v, .p = head.p, .c = t.c, .batch = head.batch, .in_stream = in_stream, .removed = head.removed, .ev = head.ev };
        }

        /// What reading a line's envelope can find wrong with it.
        const HeaderError = error{ CorruptRecord, ChecksumMismatch };

        /// Only the schema and migration hook determine how an event is read.
        /// A walk owns this value rather than observing the journal as it goes.
        const Decoder = struct {
            schema_version: u32,
            migrate: ?Migrate,
        };

        /// What a walk needs to read an event, copied so that the walk reads
        /// records without observing the journal.
        fn captureDecoder(self: *const Self) Decoder {
            return .{ .schema_version = self.config.schema_version, .migrate = self.config.migrate };
        }

        /// Finish a header into a record whose every slice comes from `arena`.
        fn recordFrom(decoding: Decoder, arena: Allocator, header: Header, line: []const u8) ReadError!Record {
            return .{
                .seq = header.seq,
                .at = header.at,
                .version = header.version,
                .stream = if (header.in_stream) |place| .{ .id = line[place.id.from..place.id.to], .version = place.version } else null,
                .event = try eventFrom(decoding, arena, header.version, header.ev, line),
                .bytes = line,
            };
        }

        fn eventFrom(
            decoding: Decoder,
            arena: Allocator,
            version: u32,
            ev: Span,
            line: []const u8,
        ) ReadError!Event {
            // The span came out of reading a line, and is cut from the bytes
            // it is handed here; a pair that do not belong together would slice
            // past the line in a build that does not check.
            aegis.assert.pre(ev.from <= ev.to and ev.to <= line.len, "an event's span lies inside the line it was read from");
            if (version == decoding.schema_version) {
                return json.parseLeaky(Event, arena, line[ev.from..ev.to], eventParse(line.len)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptRecord,
                };
            }
            if (version > decoding.schema_version) return error.NewerSchema;
            if (decoding.migrate) |migrate| return migrate(arena, version, try retainedEv(arena, ev, line));
            if (comptime unknown_arm != null) return unknownEvent(arena, ev, line);
            return error.OlderSchema;
        }

        /// The record's `ev` member as its bytes, checked as JSON: a slice of
        /// the record's line, which lasts as long as the record does.
        fn retainedEv(arena: Allocator, ev: Span, line: []const u8) ReadError!Raw {
            return json.parseLeaky(Raw, arena, line[ev.from..ev.to], eventParse(line.len)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
        }

        fn unknownEvent(arena: Allocator, ev: Span, line: []const u8) ReadError!Event {
            switch (comptime unknown_arm.?) {
                .empty => return @unionInit(Event, "unknown", {}),
                .raw => return @unionInit(Event, "unknown", try retainedEv(arena, ev, line)),
                .json_value => return @unionInit(
                    Event,
                    "unknown",
                    json.parseLeaky(json.Value, arena, line[ev.from..ev.to], eventParse(line.len)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.CorruptRecord,
                    },
                ),
            }
        }

        fn readSnapshot(self: *Self, s: *State, io: Io) OpenWithSnapshotError!?Snapshot {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();

            const Document = struct { seq: u64, state: []const u8 };
            const document = (readDocument(
                s,
                io,
                arena.allocator(),
                Document,
                Log.snapshot_name,
                self.config.max_snapshot_bytes,
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
            const through: Seq = .fromRaw(document.seq);
            if (values.below(s.seq, through)) return null;
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(document.state) catch return error.CorruptSnapshot;
            const state = try self.gpa.alloc(u8, size);
            errdefer self.gpa.free(state);
            decoder.decode(state, document.state) catch return error.CorruptSnapshot;
            return .{ .seq = through, .state = state, .gpa = self.gpa };
        }
    };
}
