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
const strand = @import("journal/jsonl.zig").strand;
const envelope = @import("journal/envelope.zig");
const Encoding = @import("journal/Encoding.zig");
const values = @import("journal/values.zig");

pub const Seq = values.Seq;
pub const Bytes = values.Bytes;
pub const Records = values.Records;
pub const beginning = values.beginning;

pub const Raw = strand.Raw;

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

        // Only the opaque journal facade hands out access to this state.

        /// The configuration supplied at open. Read through `openedWith`.
        /// Fixed for the journal's life, so read without the lock.
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
            /// Reset once per record while reading records back; never holds
            /// anything a caller can see.
            scratch: std.heap.ArenaAllocator,
            sinks: std.ArrayList(Sink),
            /// Bumped by `nudge`: a wake with no record behind it.
            nudges: u64,
            /// The sequence number of the newest record, or zero. Read it with
            /// `lastSeq`, which takes the lock.
            seq: Seq,

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
                // The records the cursor has already passed, counted from the first.
                const passed = values.span(first, cursor) orelse Records.fromRaw(items.len);
                const skip = @min(values.limit(passed), items.len);
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

        /// Only the opaque batch facade hands out access to this state.
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
                const gpa = batch.arena.child_allocator;
                batch.arena.deinit();
                gpa.destroy(batch);
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
            at: i64,
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
            /// `std.json.Value` — and `error.OlderSchema` if there is not.
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

        pub const Opened = struct {
            journal: *Self,
            snapshot: ?Snapshot,
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

        pub const CompactError = OpenError || Log.CompactError || error{PersistenceFailed};

        pub const DropError = Log.CompactError;

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

        const UnknownArm = enum { empty, raw, json_value };

        /// Whether `Event` has an arm this package can put an unrecognised
        /// older record into, and what shape it is.
        /// How an event is parsed out of its record: by every read, and by
        /// the append that proves the event reads back. One value, so an
        /// append never writes what a read refuses. Strict, because an event
        /// that writes a member it does not read back would not come back
        /// as the event that was appended.
        const event_parse: strand.ParseOptions = .{ .ignore_unknown_fields = false };

        const unknown_arm: ?UnknownArm = blk: {
            if (@typeInfo(Event) != .@"union" or !@hasField(Event, "unknown")) break :blk null;
            const Arm = @FieldType(Event, "unknown");
            if (Arm == void) break :blk .empty;
            if (Arm == Raw) break :blk .raw;
            if (Arm == std.json.Value) break :blk .json_value;
            break :blk null;
        };

        //====================================================================
        // Opening.
        //====================================================================

        pub fn open(gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const log = try Log.open(gpa, io, path, .{
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

            self.* = .{
                .gpa = gpa,
                .config = options,
                .state = .init(.{
                    .log = log,
                    .tail = .{},
                    .record_hint = 256,
                    .line = .empty,
                    .scratch = .init(gpa),
                    .sinks = .empty,
                    .nudges = 0,
                    .seq = values.beginning,
                    .write_failed = false,
                }),
                .changed = .initLimit(std.math.maxInt(usize)),
            };
            errdefer {
                // No other task has the journal yet.
                const s = self.state.teardown();
                s.log.deinit(io);
                self.release(s);
            }
            {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                try self.fillTail(s, io);
            }
            if (options.verify == .full) _ = try self.verify(io);
            return self;
        }

        pub fn openWithSnapshot(
            gpa: Allocator,
            io: Io,
            path: []const u8,
            options: Options,
        ) OpenWithSnapshotError!Opened {
            const self = try open(gpa, io, path, options);
            errdefer self.deinit(io);
            const found = snapshot_read: {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                break :snapshot_read try self.readSnapshot(s, io);
            };
            return .{ .journal = self, .snapshot = found };
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
            defer {
                guard.deinit(io);
                self.gpa.destroy(self);
            }
            const s = guard.value();
            s.log.deinit(io);
            self.release(s);
        }

        fn release(self: *Self, s: *State) void {
            s.clearTail();
            s.tail.deinit(self.gpa);
            s.line.deinit(self.gpa);
            s.sinks.deinit(self.gpa);
            s.scratch.deinit();
        }

        //====================================================================
        // Writing.
        //====================================================================

        pub fn append(self: *Self, io: Io, at: i64, event: Event) AppendError!Seq {
            return self.appendOne(io, null, at, event, .now) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendDeferred(self: *Self, io: Io, at: i64, event: Event) AppendError!Seq {
            return self.appendOne(io, null, at, event, .deferred) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendIf(self: *Self, io: Io, expected: Expected, at: i64, event: Event) AppendIfError!Seq {
            return self.appendOne(io, expected, at, event, .now);
        }

        fn appendOne(self: *Self, io: Io, expected: ?Expected, at: i64, event: Event, durability: enum { now, deferred }) AppendIfError!Seq {
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
            try s.expect(expected);
            const next = try values.successor(s.seq);
            // Built before the write: a record the journal could not hold is a
            // record that must not reach the disk either.
            var built = try self.encode(s, next, at, s.log.chainTip(), event, null);
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

            held = self.publish(s, built);
            self.wake(io);
            // Last, so that a sink reading this record was reading memory that
            // still existed.
            self.trimTail(s);
            return next;
        }

        pub fn appendAll(self: *Self, io: Io, entries: []const Entry, commit: Commit) AppendError!Seq {
            return self.appendBatch(io, null, entries, commit) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendAllIf(self: *Self, io: Io, expected: Expected, entries: []const Entry, commit: Commit) AppendIfError!Seq {
            return self.appendBatch(io, expected, entries, commit);
        }

        fn appendBatch(self: *Self, io: Io, expected: ?Expected, entries: []const Entry, commit: Commit) AppendIfError!Seq {
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
            try s.expect(expected);
            if (entries.len == 0) return s.seq;
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
                const numbered = values.advance(before, .fromRaw(i + 1)) catch unreachable; // unreachable: the last of them, `last`, was numbered above
                var item = self.encode(s, numbered, entry.at, link, entry.event, batch) catch |err| {
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
            return last;
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

        pub fn copySince(self: *Self, gpa: Allocator, io: Io, cursor: Seq) CopyError!*Batch {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            const window = s.tailSince(cursor);
            const batch = try gpa.create(Batch);
            batch.* = .{ .records = &.{}, .complete = window.complete, .arena = .init(gpa) };
            errdefer batch.deinit();
            const a = batch.arena.allocator();
            const copied = try a.alloc(Record, window.records.len);
            for (window.records, copied) |owned, *copy| {
                const record = owned.record;
                copy.* = record;
                copy.bytes = try a.dupe(u8, record.bytes);
                copy.event = try strand.copyOwned(a, record.event);
            }
            batch.records = copied;
            return batch;
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
            /// Its own, so that two walks and an `append` never share one.
            scratch: std.heap.ArenaAllocator,
            run: Continuity,
            /// The last record read whole: handed on, or stepped over.
            last: ?Position.Last = null,
            /// Every atomic batch up to here is whole: what the journal held
            /// when the walk was chosen, and the last record of every batch
            /// found whole since. A record of a batch past it is handed on
            /// only once the batch's last record is in the file.
            whole_through: Seq,

            pub fn deinit(walk: *Replay, io: Io) void {
                const gpa = walk.scan.gpa;
                defer gpa.destroy(walk);
                walk.scan.deinit(io);
                walk.arena.deinit();
                walk.scratch.deinit();
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
                _ = walk.scratch.reset(.retain_capacity);
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
                    const header = line.parse(walk.scratch.allocator(), parseHeader) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.StalePosition,
                    };
                    if (header.seq != last.seq or header.c != last.checksum) return error.StalePosition;
                    walk.run.expected = values.following(last.seq);
                    walk.run.link = last.checksum;
                    walk.last = last;
                }
            }

            pub fn next(walk: *Replay, io: Io) ReplayError!?Record {
                while (try walk.scan.next(io)) |line| {
                    if (walk.scan.takeBoundary()) |boundary| try walk.run.beginSegment(boundary);
                    _ = walk.scratch.reset(.retain_capacity);
                    const header = try line.parse(walk.scratch.allocator(), parseHeader);
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
                    if (!try walk.run.accept(header)) {
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

        pub fn replay(self: *Self, io: Io, cursor: Seq) ReplayError!*Replay {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            return self.replayFrom(s, io, cursor, false);
        }

        /// `replay`, saying whether the walk may build an index it finds
        /// missing. The scan is chosen under the lock `s` is held through,
        /// whether or not it may build an index.
        fn replayFrom(self: *Self, s: *State, io: Io, cursor: Seq, may_write: bool) ReplayError!*Replay {
            const walk = try self.gpa.create(Replay);
            errdefer self.gpa.destroy(walk);
            var scan = try s.log.scanFrom(io, cursor, .{ .may_write = may_write });
            errdefer scan.deinit(io);
            walk.* = .{
                .journal = self,
                .decoder = self.captureDecoder(),
                .scan = scan,
                .arena = .init(self.gpa),
                .scratch = .init(self.gpa),
                .run = .{ .cursor = cursor },
                .whole_through = s.seq,
            };
            return walk;
        }

        pub fn replayAt(self: *Self, io: Io, position: Position) ReplayAtError!*Replay {
            const walk = initialized: {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                const result = try self.gpa.create(Replay);
                errdefer self.gpa.destroy(result);
                var scan = try s.log.scanIdle();
                errdefer scan.deinit(io);
                result.* = .{
                    .journal = self,
                    .decoder = self.captureDecoder(),
                    .scan = scan,
                    .arena = .init(self.gpa),
                    .scratch = .init(self.gpa),
                    .run = .{ .cursor = position.cursor },
                    .whole_through = s.seq,
                };
                break :initialized result;
            };
            errdefer walk.deinit(io);
            try walk.rearmAt(io, position);
            return walk;
        }

        pub fn verify(self: *Self, io: Io) ReplayError!Records {
            var walk = chosen: {
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                break :chosen try self.replayFrom(s, io, s.log.baseSeq(), false);
            };
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

        pub fn seqAtOrAfter(self: *Self, io: Io, at: i64) SeekError!?Seq {
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
                var walk = try self.replayFrom(s, io, cursor, true);
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
                const gpa = tail.gpa;
                defer gpa.destroy(tail);
                tail.gpa.free(tail.name);
                tail.* = undefined;
            }

            pub fn replay(tail: *Tailer, io: Io) ReplayError!*Replay {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();
                return self.replayFrom(s, io, tail.committed, false);
            }

            pub fn commit(tail: *Tailer, io: Io, seq: Seq) TailerError!void {
                const self = tail.journal;
                var guard = try self.state.acquire(io);
                defer guard.deinit(io);
                const s = guard.value();

                var document: std.Io.Writer.Allocating = .init(self.gpa);
                defer document.deinit();
                strand.writeValue(&document.writer, .{ .fmt = document_format, .seq = seq.raw() }, .{}) catch
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
                s.log.dir.deleteFile(io, file) catch |err| switch (err) {
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

        /// Only the opaque readers facade hands out access to this state.
        pub const Readers = struct {
            items: []const Reader,
            arena: std.heap.ArenaAllocator,

            pub fn deinit(list: *Readers) void {
                const gpa = list.arena.child_allocator;
                list.arena.deinit();
                gpa.destroy(list);
            }
        };

        pub fn readers(self: *Self, gpa: Allocator, io: Io) TailerError!*Readers {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();

            const list = try gpa.create(Readers);
            list.* = .{ .items = &.{}, .arena = .init(gpa) };
            errdefer list.deinit();
            const a = list.arena.allocator();
            var found: std.ArrayList(Reader) = .empty;

            var iterator = s.log.dir.iterate();
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
            return list;
        }

        pub fn minCursor(self: *Self, io: Io) TailerError!?Seq {
            const list = try self.readers(self.gpa, io);
            defer list.deinit();
            var lowest: ?Seq = null;
            for (list.items) |reader| {
                lowest = if (lowest) |value| values.lesser(value, reader.cursor) else reader.cursor;
            }
            return lowest;
        }

        pub fn tailer(self: *Self, io: Io, name: []const u8) TailerError!*Tailer {
            var guard = try self.state.acquire(io);
            defer guard.deinit(io);
            const s = guard.value();
            if (!validTailerName(name)) return error.InvalidName;
            const tail = try self.gpa.create(Tailer);
            errdefer self.gpa.destroy(tail);
            const owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned);
            tail.* = .{ .journal = self, .gpa = self.gpa, .name = owned, .committed = try self.readCursor(s, io, owned) };
            return tail;
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
            limit: usize,
        ) DocumentError!?Document {
            const bytes = s.log.dir.readFileAlloc(
                io,
                name,
                arena,
                .limited(limit),
            ) catch |err| switch (err) {
                error.FileNotFound => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.StreamTooLong => return error.StreamTooLong,
                else => return error.MalformedDocument,
            };
            const Versioned = struct { fmt: u32 };
            const version = strand.parseLine(Versioned, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedDocument,
            };
            if (version.fmt != document_format) return error.UnsupportedFormat;
            return strand.parseLine(Document, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
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
            const document = readDocument(
                s,
                io,
                arena.allocator(),
                Document,
                file,
                4096,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.UnsupportedFormat => return error.UnsupportedFormat,
                else => return error.CorruptCursor,
            } orelse return null;
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
            strand.writeValue(&document.writer, .{ .fmt = document_format, .seq = s.seq.raw(), .state = b64 }, .{}) catch
                return error.OutOfMemory;

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
            const document = readDocument(
                s,
                io,
                arena.allocator(),
                Document,
                Log.snapshot_name,
                values.limit(self.config.max_snapshot_bytes),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return,
            } orelse return;
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
            try s.log.compact(io, keep_after_seq);
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
            at: i64,
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

        /// Serialise one record.
        ///
        /// Where something will read the record back — a tail, a sink, or the
        /// round-trip check asked for — it is parsed back out of the bytes
        /// that will be written, so what memory holds is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append. Where nothing will, that parse would build a record
        /// and drop it unread, so it is not done.
        fn encode(self: *Self, s: *State, seq: Seq, at: i64, back_link: u32, event: Event, batch: ?envelope.Batch) AppendError!Built {
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

            // The bytes are the ones `std.json.Stringify` writes for a
            // `Line`, written into the one buffer that becomes the stored
            // bytes; the suite's golden lines, its property over every shape
            // and a log written before strand hold it to that.
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
            // The record is `Line` written by strand, which writes what
            // `std.json` writes (null optionals included, as `std.json`'s
            // default has it), left open: the checksum is its last member.
            const value_options: strand.ValueOptions = .{ .emit_null_optional_fields = true };
            var record = if (batch) |b| strand.writeObjectOpen(&out.writer, LineInBatch{
                .seq = seq.raw(),
                .at = at,
                .v = self.config.schema_version,
                .p = back_link,
                .bf = b.first.raw(),
                .bl = b.last.raw(),
                .ev = event,
            }, value_options) catch |err| return encoding.diagnose(err) else strand.writeObjectOpen(&out.writer, Line{
                .seq = seq.raw(),
                .at = at,
                .v = self.config.schema_version,
                .p = back_link,
                .ev = event,
            }, value_options) catch |err| return encoding.diagnose(err);
            // The checksum covers everything the record says except the
            // checksum itself: the object so far, before `,"c":<crc>}` closes
            // it.
            const covered_len = out.written().len;
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
            const span = (envelope.quick(stored[0..covered_len]) orelse return error.NotRoundTrippable).ev;
            const parsed = strand.parseLine(
                Event,
                arena.?.allocator(),
                stored[span.from..span.to],
                event_parse,
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
                _ = s.scratch.reset(.retain_capacity);
                const header = try line.parse(s.scratch.allocator(), parseHeader);
                if (!try run.accept(header)) continue;

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
            s.tail.deinit(self.gpa);
            s.tail = rebuilt;
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
            at: i64,
            version: u32,
            /// The checksum of the record before this one.
            p: u32,
            /// This record's own checksum, which the next one carries as its
            /// `p`.
            c: u32,
            /// The atomic batch the record was written in, if it was.
            batch: ?envelope.Batch,
            /// Where the event sits in the line, still unparsed.
            ev: Span,
        };

        const Span = envelope.Span;

        /// Read a line's envelope, checking its checksum.
        ///
        /// `scratch` holds nothing unless the line is not in the shape this
        /// package writes, in which case it holds what reading it took.
        fn parseHeader(scratch: Allocator, line: []const u8) ReadError!Header {
            // A line that does not end in a checksum is not a record and
            // there is nothing to check it against.
            const t = envelope.trailer(line) orelse return error.CorruptRecord;
            if (checksum(t.covered) != t.c) return error.ChecksumMismatch;
            const head = envelope.quick(t.covered) orelse envelope.members(scratch, line) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Corrupt => return error.CorruptRecord,
            };
            return .{ .seq = head.seq, .at = head.at, .version = head.v, .p = head.p, .c = t.c, .batch = head.batch, .ev = head.ev };
        }

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
                return strand.parseLine(Event, arena, line[ev.from..ev.to], event_parse) catch |err| switch (err) {
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
            return strand.parseLine(Raw, arena, line[ev.from..ev.to], .{}) catch |err| switch (err) {
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
                    strand.parseLine(std.json.Value, arena, line[ev.from..ev.to], .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
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
                values.limit(self.config.max_snapshot_bytes),
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
