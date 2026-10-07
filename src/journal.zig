//! The private state and operations behind the managed owners.
//! chronicle.zig is the package API, and documents every declaration it
//! hands out; this file documents only what it keeps to itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const continuity = @import("journal/continuity.zig");
const Log = @import("journal/Log.zig");
const crc32c = @import("journal/crc32c.zig");
const strand = @import("journal/jsonl.zig").strand;
const envelope = @import("journal/envelope.zig");
const Encoding = @import("journal/Encoding.zig");

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

pub fn segmentName(base_seq: u64) [Log.name_digits + segment_extension.len:0]u8 {
    return Log.segmentName(segment_extension, base_seq);
}

pub fn indexName(base_seq: u64) [Log.name_digits + index_extension.len:0]u8 {
    return Log.segmentName(index_extension, base_seq);
}

pub const document_format: u32 = 1;

pub fn checksum(covered: []const u8) u32 {
    return crc32c.hash(covered);
}

pub const Position = struct {
    /// The reader has every record up to and including this sequence
    /// number: what it would pass to `replay`.
    cursor: u64,
    /// The last record the walk read, handed on or stepped over; null when
    /// it read none, in which case `replayAt` is `replay` from `cursor`.
    last: ?Last = null,

    pub const Last = struct {
        seq: u64,
        /// The segment holding it, by the sequence number it is named after.
        segment: u64,
        /// Where its line starts in the segment's file, and where the next
        /// one starts.
        start: u64,
        end: u64,
        /// Its checksum, which the record after it carries as its back-link.
        checksum: u32,
    };

    /// A position that is only a cursor: `replayAt` from it is `replay`.
    pub fn after(cursor: u64) Position {
        return .{ .cursor = cursor };
    }
};

pub fn Journal(comptime Event: type) type {
    return struct {
        const Self = @This();

        // Only the opaque journal facade hands out access to this state.

        /// The configuration supplied at open. Read through `options`.
        config: Options,

        //-------------------------------------------------------------- internals

        /// The allocator every allocation comes from. Owned by the caller; the
        /// journal never outlives it.
        gpa: Allocator,
        /// A failed persistence operation refuses writes until reconciliation.
        /// Read only through `status`, under the journal's lock.
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
        mutex: Io.Mutex,
        /// Bumped under the lock by every append and every nudge, and
        /// waited on by `waitPast` (`wake`). A futex word rather than an
        /// `Io.Condition`: Zig 0.16.0's condition drops a cancel that
        /// lands in the same instant as a broadcast — its wait consumes the
        /// broadcast and returns without `error.Canceled`, and the cancel is
        /// gone — so a reader stopped as a record arrives waited on forever.
        changed: std.atomic.Value(u32),
        /// Bumped by `nudge`: a wake with no record behind it.
        nudges: u64,
        /// How many `waitPast` calls are between letting go of the lock and
        /// taking it back, which is to say may be asleep on `changed`.
        /// Kept under the lock. With none, a wake bumps the word and makes
        /// no system call: an append nobody waits on pays nothing for the
        /// readers it does not have.
        waiters: u32,
        /// How many wakes went to the operating system. Not part of any
        /// promise: what the suite counts to prove that an append with no
        /// reader waiting makes none.
        futex_wakes: u64,
        /// The sequence number of the newest record, or zero. Read it with
        /// `lastSeq`, which takes the lock.
        seq: u64,

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
                    std.debug.assert(tail.entries.items[tail.entries.items.len - 1].record.seq < owned.record.seq);
                }
                tail.entries.appendAssumeCapacity(owned);
                tail.bytes += owned.record.bytes.len;
            }

            fn trim(tail: *Tail, settings: Options) void {
                var drop: usize = 0;
                var held = tail.bytes;
                while (tail.entries.items.len - drop > settings.tail_records or
                    (held > settings.tail_bytes and drop < tail.entries.items.len))
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
            /// Zero uses one byte, the lookahead needed to recognize a line.
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

        pub const Snapshot = struct {
            seq: u64,
            state: []const u8,

            /// Free `state`, through the allocator `openWithSnapshot` was given.
            pub fn deinit(found: Snapshot, gpa: Allocator) void {
                gpa.free(found.state);
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

        pub const AppendError = Allocator.Error || Log.AppendError ||
            error{ PersistenceFailed, NotRoundTrippable, SequenceExhausted, RecordTooLarge };

        pub const AppendIfError = AppendError || error{WrongExpectedSeq};

        pub const Expected = struct {
            /// The sequence number the newest record must still have: zero
            /// for a journal that must still be empty.
            last: u64,
            /// Where `error.WrongExpectedSeq` leaves the sequence number the
            /// newest record has instead, read under the same lock as the
            /// comparison. Not written when the append goes ahead.
            found: ?*u64 = null,
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

        pub const CloseError = Log.CloseError;

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

        pub fn open(gpa: Allocator, io: Io, path: []const u8, settings: Options) OpenError!*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const log = try Log.open(gpa, io, path, .{
                .access = settings.access,
                .on_truncated = settings.on_truncated,
                .sync = settings.sync,
                .write_buffer_size = settings.write_buffer_size,
                .read_buffer_size = settings.read_buffer_size,
                .max_segment_bytes = settings.max_segment_bytes,
                .max_segment_records = settings.max_segment_records,
                .preallocate_bytes = settings.preallocate_bytes,
                .index_interval_bytes = settings.index_interval_bytes,
                .max_record_bytes = settings.max_record_bytes,
            });

            self.* = .{
                .gpa = gpa,
                .log = log,
                .config = settings,
                .tail = .{},
                .record_hint = 256,
                .line = .empty,
                .scratch = .init(gpa),
                .sinks = .empty,
                .mutex = .init,
                .changed = .init(0),
                .nudges = 0,
                .waiters = 0,
                .futex_wakes = 0,
                .seq = 0,
                .write_failed = false,
            };
            errdefer {
                self.log.deinit(io);
                self.release();
            }
            {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                try self.fillTail(io);
            }
            if (settings.verify == .full) _ = try self.verify(io);
            return self;
        }

        pub fn openWithSnapshot(
            gpa: Allocator,
            io: Io,
            path: []const u8,
            settings: Options,
        ) OpenWithSnapshotError!Opened {
            const self = try open(gpa, io, path, settings);
            errdefer self.deinit(io);
            const found = snapshot_read: {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                break :snapshot_read try self.readSnapshot(io);
            };
            return .{ .journal = self, .snapshot = found };
        }

        pub fn close(self: *Self, io: Io) CloseError!void {
            // A close that has begun flushes and seals to its end, whatever
            // a cancel asks of the task meanwhile.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            self.mutex.lockUncancelable(io);
            defer {
                self.mutex.unlock(io);
                self.gpa.destroy(self);
            }
            defer self.release();
            try self.log.close(io);
        }

        pub fn deinit(self: *Self, io: Io) void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            self.mutex.lockUncancelable(io);
            defer {
                self.mutex.unlock(io);
                self.gpa.destroy(self);
            }
            self.log.deinit(io);
            self.release();
        }

        fn release(self: *Self) void {
            self.clearTail();
            self.tail.deinit(self.gpa);
            self.line.deinit(self.gpa);
            self.sinks.deinit(self.gpa);
            self.scratch.deinit();
        }

        //====================================================================
        // Writing.
        //====================================================================

        pub fn append(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            return self.appendOne(io, null, at, event, .now) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendDeferred(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            return self.appendOne(io, null, at, event, .deferred) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendIf(self: *Self, io: Io, expected: Expected, at: i64, event: Event) AppendIfError!u64 {
            return self.appendOne(io, expected, at, event, .now);
        }

        /// Refuse a conditional append whose journal has moved on. Called
        /// under the lock, after everything that says the journal cannot be
        /// appended to at all, and before anything is written.
        fn expect(self: *const Self, expected: ?Expected) error{WrongExpectedSeq}!void {
            const want = expected orelse return;
            if (self.seq == want.last) return;
            if (want.found) |found| found.* = self.seq;
            return error.WrongExpectedSeq;
        }

        fn appendOne(self: *Self, io: Io, expected: ?Expected, at: i64, event: Event, durability: enum { now, deferred }) AppendIfError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
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
            if (self.write_failed) return error.PersistenceFailed;
            try self.expect(expected);
            if (self.seq >= std.math.maxInt(i64)) return error.SequenceExhausted;

            const next = self.seq + 1;
            // Built before the write: a record the journal could not hold is a
            // record that must not reach the disk either.
            var built = try self.encode(next, at, self.log.chainTip(), event, null);
            var held = false;
            defer if (!held) built.release();

            // Reserve before writing: after the bytes are durable nothing may
            // fail, or the disk would hold a record memory does not.
            if (self.keepsRecords()) try self.tail.entries.ensureUnusedCapacity(self.gpa, 1);

            {
                errdefer self.write_failed = true;
                switch (durability) {
                    .now => try self.log.appendLine(io, built.bytes, built.at, built.checksum),
                    .deferred => {
                        try self.log.stageLine(io, built.bytes, built.at, built.checksum, .may_rotate);
                        try self.log.commitDeferred();
                    },
                }
            }

            held = self.publish(built);
            self.wake(io);
            // Last, so that a sink reading this record was reading memory that
            // still existed.
            self.trimTail();
            return next;
        }

        pub fn appendAll(self: *Self, io: Io, entries: []const Entry, commit: Commit) AppendError!u64 {
            return self.appendBatch(io, null, entries, commit) catch |err| switch (err) {
                error.WrongExpectedSeq => unreachable,
                else => |e| return e,
            };
        }

        pub fn appendAllIf(self: *Self, io: Io, expected: Expected, entries: []const Entry, commit: Commit) AppendIfError!u64 {
            return self.appendBatch(io, expected, entries, commit);
        }

        fn appendBatch(self: *Self, io: Io, expected: ?Expected, entries: []const Entry, commit: Commit) AppendIfError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (self.write_failed) return error.PersistenceFailed;
            try self.expect(expected);
            if (entries.len == 0) return self.seq;
            if (entries.len > std.math.maxInt(i64) - self.seq) return error.SequenceExhausted;

            // Reserved before anything is written: after the bytes are
            // durable nothing may fail, or the disk would hold records
            // memory does not.
            if (self.keepsRecords()) try self.tail.entries.ensureUnusedCapacity(self.gpa, entries.len);

            // Only the records something will read are kept: a journal with
            // no tail and no sink holds one line at a time, however long the
            // batch is.
            var built: std.ArrayList(Built) = .empty;
            defer built.deinit(self.gpa);
            var published = false;
            defer if (!published) for (built.items) |*item| item.release();
            if (self.keepsRecords()) try built.ensureTotalCapacityPrecise(self.gpa, entries.len);

            const before = self.seq;
            // An atomic batch names itself in every record it writes, so an
            // open that finds the log ending inside one drops it whole; a
            // batch of one record is whole or absent anyway, and says nothing.
            const batch: ?envelope.Batch = if (commit == .atomic and entries.len > 1)
                .{ .first = before + 1, .last = before + entries.len }
            else
                null;
            var link = self.log.chainTip();
            const staged_from = self.log.mark();
            for (entries, 0..) |entry, i| {
                var item = self.encode(self.seq + i + 1, entry.at, link, entry.event, batch) catch |err| {
                    self.unstage(io, staged_from);
                    return err;
                };
                link = item.checksum;
                // A batch is never split across segments: only its first
                // record may start a new one.
                const rotation: Log.Rotation = if (batch != null and i != 0) .stay else .may_rotate;
                {
                    errdefer self.write_failed = true;
                    self.log.stageLine(io, item.bytes, item.at, item.checksum, rotation) catch |err| {
                        item.release();
                        return err;
                    };
                }
                if (self.keepsRecords()) built.appendAssumeCapacity(item) else item.release();
            }

            {
                errdefer self.write_failed = true;
                try self.log.commit(io);
            }
            published = true;

            for (built.items) |*item| {
                _ = self.publish(item.*);
            }
            // A batch of records nothing keeps still moved the sequence.
            self.seq = before + entries.len;
            self.wake(io);
            self.trimTail();
            return self.seq;
        }

        pub fn reconcile(self: *Self, io: Io) ReconcileError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (!self.write_failed) return self.seq;

            const previous = self.seq;
            try self.log.reload(io);
            self.clearTail();
            try self.fillTail(io);
            self.write_failed = false;
            try self.caughtUp(io, previous);
            return self.seq;
        }

        /// Take back the lines of a batch that was staged and never
        /// committed, so that a batch which could not be formed leaves the
        /// log exactly as it was. Nothing staged was published, so the tail
        /// and the sinks never saw it.
        ///
        /// What is on the disk has to end at a record boundary whatever
        /// happened. Nothing here was ever acknowledged, so nothing is lost
        /// by it.
        fn unstage(self: *Self, io: Io, from: Log.Mark) void {
            self.log.discardStaged(io, from) catch {
                // The log could not be put back. What this process staged
                // may reach the disk as records it never acknowledged, so it
                // must not append after them until `reconcile` has read
                // what is there.
                self.write_failed = true;
            };
        }

        pub fn nudge(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.nudges +%= 1;
            self.wake(io);
        }

        //====================================================================
        // Reading.
        //====================================================================

        pub fn copySince(self: *Self, gpa: Allocator, io: Io, cursor: u64) CopyError!*Batch {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const window = self.tailSince(cursor);
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

        /// The tail after a cursor. The caller holds the journal's lock for
        /// the whole lifetime of this borrow.
        fn tailSince(self: *const Self, cursor: u64) TailWindow {
            const items = self.tail.entries.items;
            if (items.len == 0) return .{ .records = items, .complete = cursor >= self.seq };
            const tail_base = items[0].record.seq - 1;
            if (cursor < tail_base) return .{ .records = items, .complete = false };
            const skip: usize = @intCast(@min(cursor - tail_base, items.len));
            return .{ .records = items[skip..], .complete = true };
        }

        pub fn waitPast(self: *Self, io: Io, cursor: u64) Io.Cancelable!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const nudged = self.nudges;
            while (self.seq <= cursor and self.nudges == nudged) {
                // read under the lock: whatever wakes this reader bumps the
                // word under the same lock, after this, so the wait returns
                const seen = self.changed.load(.acquire);
                // counted before the lock goes, so a wake from here on
                // knows there is somebody to wake
                self.waiters += 1;
                self.mutex.unlock(io);
                const waited = io.futexWait(u32, &self.changed.raw, seen);
                self.mutex.lockUncancelable(io);
                self.waiters -= 1;
                try waited;
            }
            return self.seq;
        }

        /// Every `waitPast` woken to look again. Called under the lock.
        ///
        /// The word is bumped whatever happens, so a reader that counted
        /// itself in and has not reached its wait yet finds it moved and
        /// does not sleep. The system call is made only when a reader has
        /// counted itself in: `waiters` is read under the same lock the
        /// reader counts itself in under, so none can be missed.
        fn wake(self: *Self, io: Io) void {
            _ = self.changed.fetchAdd(1, .release);
            if (self.waiters == 0) return;
            self.futex_wakes += 1;
            io.futexWake(u32, &self.changed.raw, std.math.maxInt(u32));
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
            whole_through: u64,

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
                        try self.mutex.lock(io);
                        defer self.mutex.unlock(io);
                        break :found try self.log.scanAtInto(io, &walk.scan, last.segment, last.start);
                    };
                    if (!found) return error.StalePosition;
                } else {
                    {
                        try self.mutex.lock(io);
                        defer self.mutex.unlock(io);
                        try self.log.scanFromInto(io, &walk.scan, at.cursor, .{});
                    }
                }
                walk.whole_through = whole: {
                    try self.mutex.lock(io);
                    defer self.mutex.unlock(io);
                    break :whole self.seq;
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
                    const header = parseHeader(walk.scratch.allocator(), line) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.StalePosition,
                    };
                    if (header.seq != last.seq or header.c != last.checksum) return error.StalePosition;
                    walk.run.expected = last.seq + 1;
                    walk.run.link = last.checksum;
                    walk.last = last;
                }
            }

            pub fn next(walk: *Replay, io: Io) ReplayError!?Record {
                while (try walk.scan.next(io)) |line| {
                    if (walk.scan.takeBoundary()) |boundary| try walk.run.beginSegment(boundary);
                    _ = walk.scratch.reset(.retain_capacity);
                    const header = try parseHeader(walk.scratch.allocator(), line);
                    if (header.batch) |batch| if (batch.last > walk.whole_through) {
                        // A batch being written beside this walk, or one a
                        // crash cut: none of it until all of it is there.
                        if (!try walk.scan.holds(io, batch.last)) {
                            try walk.scan.rewind(io, line.len + 1);
                            return null;
                        }
                        walk.whole_through = batch.last;
                    };
                    // Stepping over a record before its event is parsed is
                    // what lets a reader hold a cursor into a log whose
                    // events it does not know.
                    if (!try walk.run.accept(header)) {
                        walk.last = walk.lastRead(header, line);
                        continue;
                    }
                    _ = walk.arena.reset(.retain_capacity);
                    const record = try recordFrom(walk.decoder, walk.arena.allocator(), header, line);
                    walk.last = walk.lastRead(header, line);
                    return record;
                }
                return null;
            }

            pub fn position(walk: *const Replay) Position {
                const last = walk.last orelse return .{ .cursor = walk.run.cursor };
                return .{ .cursor = @max(walk.run.cursor, last.seq), .last = last };
            }

            /// The record just read, where it lies in its file.
            fn lastRead(walk: *const Replay, header: Header, line: []const u8) Position.Last {
                return .{
                    .seq = header.seq,
                    .segment = walk.scan.bases[walk.scan.at],
                    .start = walk.scan.position - line.len - 1,
                    .end = walk.scan.position,
                    .checksum = header.c,
                };
            }
        };

        pub fn replay(self: *Self, io: Io, cursor: u64) ReplayError!*Replay {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.replayFrom(io, cursor, false);
        }

        /// `replay`, saying whether the walk may build an index it finds
        /// missing. The caller holds the journal's lock while choosing the
        /// scan, whether or not it may build an index.
        fn replayFrom(self: *Self, io: Io, cursor: u64, may_write: bool) ReplayError!*Replay {
            const walk = try self.gpa.create(Replay);
            errdefer self.gpa.destroy(walk);
            var scan = try self.log.scanFrom(io, cursor, .{ .may_write = may_write });
            errdefer scan.deinit(io);
            walk.* = .{
                .journal = self,
                .decoder = self.captureDecoder(),
                .scan = scan,
                .arena = .init(self.gpa),
                .scratch = .init(self.gpa),
                .run = .{ .cursor = cursor },
                .whole_through = self.seq,
            };
            return walk;
        }

        pub fn replayAt(self: *Self, io: Io, position: Position) ReplayAtError!*Replay {
            const walk = initialized: {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                const result = try self.gpa.create(Replay);
                errdefer self.gpa.destroy(result);
                var scan = try self.log.scanIdle();
                errdefer scan.deinit(io);
                result.* = .{
                    .journal = self,
                    .decoder = self.captureDecoder(),
                    .scan = scan,
                    .arena = .init(self.gpa),
                    .scratch = .init(self.gpa),
                    .run = .{ .cursor = position.cursor },
                    .whole_through = self.seq,
                };
                break :initialized result;
            };
            errdefer walk.deinit(io);
            try walk.rearmAt(io, position);
            return walk;
        }

        pub fn verify(self: *Self, io: Io) ReplayError!u64 {
            var walk = chosen: {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                break :chosen try self.replayFrom(io, self.log.baseSeq(), false);
            };
            defer walk.deinit(io);
            var seen: u64 = 0;
            while (try walk.next(io)) |_| seen += 1;
            return seen;
        }

        pub fn lastSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.seq;
        }

        pub fn seqAtOrAfter(self: *Self, io: Io, at: i64) SeekError!?u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.log.seqAtOrAfter(io, at);
        }

        pub fn refresh(self: *Self, io: Io) OpenError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const previous = self.seq;
            try self.log.reload(io);
            self.clearTail();
            try self.fillTail(io);
            try self.caughtUp(io, previous);
        }

        pub fn segmentCount(self: *Self, io: Io) Io.Cancelable!usize {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.log.segments.items.len;
        }

        pub fn oldestSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.log.baseSeq() + 1;
        }

        pub fn options(self: *Self, io: Io) Io.Cancelable!Options {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.config;
        }

        pub const Status = struct {
            /// Whether a persistence operation failed. Writes stay refused
            /// until `reconcile` succeeds; see `AppendError.PersistenceFailed`.
            persistence_failed: bool,
            /// How many unterminated bytes were dropped from the newest
            /// segment during opening or recovery. Zero when none were dropped.
            dropped_bytes: usize,
            /// The call the records last got when they were made durable:
            /// `flush`, or on Linux `.data` for a write into reserved space,
            /// and `.plain` where the filesystem declined the stronger call
            /// — `F_FULLFSYNC` on a network mount. Null before a sync.
            flushed: ?Flush,
        };

        pub fn status(self: *Self, io: Io) Io.Cancelable!Status {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return .{
                .persistence_failed = self.write_failed,
                .dropped_bytes = self.log.dropped_bytes,
                .flushed = self.log.flushed,
            };
        }

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
                .newest_seq = if (empty) 0 else self.seq,
            };
        }

        pub fn subscribe(self: *Self, io: Io, sink: Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, 0);
        }

        pub fn subscribeFrom(self: *Self, io: Io, sink: Sink, cursor: u64) SubscribeError!void {
            return self.subscribeAllFrom(io, &.{sink}, cursor);
        }

        pub fn subscribeAll(self: *Self, io: Io, sinks: []const Sink) SubscribeError!void {
            return self.subscribeAllFrom(io, sinks, 0);
        }

        pub fn subscribeAllFrom(self: *Self, io: Io, sinks: []const Sink, cursor: u64) SubscribeError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A fold restored to `cursor` needs the record after it. Zero
            // asks for whatever the log holds, which is no promise to miss.
            if (cursor != 0 and cursor < self.log.baseSeq()) return error.HistoryDropped;
            const before = self.sinks.items.len;
            try self.sinks.appendSlice(self.gpa, sinks);
            errdefer self.sinks.shrinkRetainingCapacity(before);
            // The registered copies, not the caller's slice: a sink that is
            // handed records here must be the same sink the next `append`
            // finds, whatever the caller does with its own array.
            const registered = self.sinks.items[before..];

            try self.deliver(io, registered, cursor);
        }

        /// Hand `sinks` every record after `cursor` up to the newest: from
        /// the tail where it reaches back that far, from the disk where it
        /// does not. Called under the journal's lock.
        fn deliver(self: *Self, io: Io, sinks: []const Sink, cursor: u64) ReplayError!void {
            if (sinks.len == 0 or cursor >= self.seq) return;
            var delivered = cursor;
            if (!self.tailSince(cursor).complete) {
                var walk = try self.replayFrom(io, cursor, true);
                defer walk.deinit(io);
                while (try walk.next(io)) |record| {
                    for (sinks) |sink| sink.f(sink.ctx, record);
                    delivered = record.seq;
                }
            }
            for (self.tailSince(delivered).records) |owned| {
                for (sinks) |sink| sink.f(sink.ctx, owned.record);
            }
        }

        /// After the files were read again: wake every `waitPast` if the
        /// newest record moved, and hand the sinks the records that arrived
        /// after `previous`, so a fold misses none of them.
        fn caughtUp(self: *Self, io: Io, previous: u64) ReplayError!void {
            if (self.seq != previous) self.wake(io);
            try self.deliver(io, self.sinks.items, previous);
        }

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

        pub const Tailer = struct {
            journal: *Self,
            gpa: Allocator,
            /// This reader's name, owned by the tailer.
            name: []const u8,
            /// Where it has got to. Zero for a name that has never committed
            /// one, and left where it was by a `compact` that dropped past
            /// it — compare it against `oldestSeq` to see what has gone.
            committed: u64,

            pub fn cursor(tail: *Tailer, io: Io) Io.Cancelable!u64 {
                const self = tail.journal;
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
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
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);
                return self.replayFrom(io, tail.committed, false);
            }

            pub fn commit(tail: *Tailer, io: Io, seq: u64) TailerError!void {
                const self = tail.journal;
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                var document: std.Io.Writer.Allocating = .init(self.gpa);
                defer document.deinit();
                strand.writeValue(&document.writer, .{ .fmt = document_format, .seq = seq }, .{}) catch
                    return error.OutOfMemory;

                const file = try cursorName(self.gpa, tail.name);
                defer self.gpa.free(file);
                try self.log.writeAtomic(io, file, document.written());
                tail.committed = seq;
            }

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

        pub const Reader = struct {
            /// Owned by the `Readers` it came in.
            name: []const u8,
            cursor: u64,
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
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const list = try gpa.create(Readers);
            list.* = .{ .items = &.{}, .arena = .init(gpa) };
            errdefer list.deinit();
            const a = list.arena.allocator();
            var found: std.ArrayList(Reader) = .empty;

            var iterator = self.log.dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind == .directory) continue;
                if (!std.mem.endsWith(u8, entry.name, cursor_extension)) continue;
                const name = entry.name[0 .. entry.name.len - cursor_extension.len];
                if (!validTailerName(name)) continue;
                // Forgotten since the listing — by another process, since
                // this one holds the lock: a reader that is gone has nothing
                // left for retention to keep, so it is not listed at zero.
                const cursor = try self.committedCursor(io, name) orelse continue;
                try found.append(a, .{ .name = try a.dupe(u8, name), .cursor = cursor });
            }
            list.items = try found.toOwnedSlice(a);
            return list;
        }

        pub fn minCursor(self: *Self, io: Io) TailerError!?u64 {
            const list = try self.readers(self.gpa, io);
            defer list.deinit();
            var lowest: ?u64 = null;
            for (list.items) |reader| {
                lowest = if (lowest) |value| @min(value, reader.cursor) else reader.cursor;
            }
            return lowest;
        }

        pub fn tailer(self: *Self, io: Io, name: []const u8) TailerError!*Tailer {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (!validTailerName(name)) return error.InvalidName;
            const tail = try self.gpa.create(Tailer);
            errdefer self.gpa.destroy(tail);
            const owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned);
            tail.* = .{ .journal = self, .gpa = self.gpa, .name = owned, .committed = try self.readCursor(io, owned) };
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
            self: *Self,
            io: Io,
            arena: Allocator,
            Document: type,
            name: []const u8,
            limit: usize,
        ) DocumentError!?Document {
            const bytes = self.log.dir.readFileAlloc(
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
        fn readCursor(self: *Self, io: Io, name: []const u8) TailerError!u64 {
            return try self.committedCursor(io, name) orelse 0;
        }

        /// The named reader's committed cursor, or null when there is no
        /// cursor file for it.
        fn committedCursor(self: *Self, io: Io, name: []const u8) TailerError!?u64 {
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
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.UnsupportedFormat => return error.UnsupportedFormat,
                else => return error.CorruptCursor,
            } orelse return null;
            return document.seq;
        }

        //====================================================================
        // Snapshots and retention.
        //====================================================================

        pub fn snapshot(self: *Self, io: Io, state_bytes: []const u8) SnapshotError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
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
                .{ document_format, self.seq },
            );
            if (encoded_size > self.config.max_snapshot_bytes or
                framing_size > self.config.max_snapshot_bytes - encoded_size)
            {
                return error.SnapshotTooLarge;
            }
            const b64 = try self.gpa.alloc(u8, encoded_size);
            defer self.gpa.free(b64);
            _ = encoder.encode(b64, state_bytes);

            var document: std.Io.Writer.Allocating = .init(self.gpa);
            defer document.deinit();
            strand.writeValue(&document.writer, .{ .fmt = document_format, .seq = self.seq, .state = b64 }, .{}) catch
                return error.OutOfMemory;

            try self.log.syncBeforeSnapshot(io);
            try self.log.writeSnapshot(io, document.written());
        }

        pub fn dropSegmentsBefore(self: *Self, io: Io, seq: u64) DropError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const dropped = try self.log.dropSegmentsBefore(io, seq);
            if (dropped != 0) self.dropTailBefore(self.log.baseSeq() + 1);
            return dropped;
        }

        pub fn truncateAfter(self: *Self, io: Io, seq: u64) TruncateError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (self.write_failed) return error.PersistenceFailed;
            if (seq < self.seq) try self.retireSnapshotAfter(io, seq);
            try self.log.truncateAfter(io, seq);
            self.clearTail();
            try self.fillTail(io);
        }

        /// Remove a snapshot folded from records after `seq`, before they
        /// are cut. The numbers a truncation frees are handed out again, so
        /// such a snapshot would later look current over a history it never
        /// saw. Gone first: a crash before the cut leaves a log with no
        /// snapshot, which replays from the start, never a stale one. A
        /// snapshot that cannot be read is left for `openWithSnapshot` to
        /// report.
        fn retireSnapshotAfter(self: *Self, io: Io, seq: u64) TruncateError!void {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const Document = struct { seq: u64 };
            const document = self.readDocument(
                io,
                arena.allocator(),
                Document,
                Log.snapshot_name,
                self.config.max_snapshot_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return,
            } orelse return;
            if (document.seq > seq) try self.log.removeSnapshot(io);
        }

        pub fn compact(self: *Self, io: Io, keep_after_seq: u64) CompactError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            // A change to the files, once begun, runs to its end: a cancel
            // is taken at the lock, before anything is written, and after it
            // at the caller's next cancelation point, never between the
            // bytes of a record and its flush.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            if (self.config.access == .read) return error.ReadOnly;
            if (self.write_failed) return error.PersistenceFailed;
            try self.log.compact(io, keep_after_seq);
            self.clearTail();
            try self.fillTail(io);
        }

        pub fn backup(self: *Self, io: Io, dest: []const u8) BackupError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.config.access == .read) {
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
        /// slice of it. A tail or sink takes ownership after the write; a
        /// round-trip check alone releases it as soon as it has been staged.
        /// When nothing will — no tail, no sink, no round-trip check —
        /// the line is the only thing built, and it is the journal's `line`:
        /// valid until the next record is encoded, which is after this one
        /// has been handed to the log.
        const Built = struct {
            arena: ?*std.heap.ArenaAllocator,
            bytes: []const u8,
            seq: u64,
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
        fn keepsRecords(self: *const Self) bool {
            return self.config.tail_records != 0 or self.sinks.items.len != 0;
        }

        /// Whether encoding must parse its result, for a reader or a check.
        fn needsRecord(self: *const Self) bool {
            return self.keepsRecords() or self.config.verify_round_trip;
        }

        /// Serialise one record.
        ///
        /// Where something will read the record back — a tail, a sink, or the
        /// round-trip check asked for — it is parsed back out of the bytes
        /// that will be written, so what memory holds is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append. Where nothing will, that parse would build a record
        /// and drop it unread, so it is not done.
        fn encode(self: *Self, seq: u64, at: i64, back_link: u32, event: Event, batch: ?envelope.Batch) AppendError!Built {
            std.debug.assert(seq > 0);
            std.debug.assert(seq <= std.math.maxInt(i64));
            if (batch) |bounds| {
                std.debug.assert(bounds.first <= seq);
                std.debug.assert(seq <= bounds.last);
            }
            const needs_record = self.needsRecord();
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
            var encoding: Encoding = .init(if (arena) |a| .init(a.allocator()) else .fromArrayList(self.gpa, &self.line));
            const out = &encoding.output;
            defer if (!needs_record) {
                self.line = out.toArrayList();
            };
            if (needs_record) {
                out.ensureTotalCapacityPrecise(self.record_hint + 32) catch return error.OutOfMemory;
            } else {
                out.clearRetainingCapacity();
            }
            // The record is `Line` written by strand, which writes what
            // `std.json` writes (null optionals included, as `std.json`'s
            // default has it), left open: the checksum is its last member.
            const value_options: strand.ValueOptions = .{ .emit_null_optional_fields = true };
            var record = if (batch) |b| strand.writeObjectOpen(&out.writer, LineInBatch{
                .seq = seq,
                .at = at,
                .v = self.config.schema_version,
                .p = back_link,
                .bf = b.first,
                .bl = b.last,
                .ev = event,
            }, value_options) catch |err| return encoding.diagnose(err) else strand.writeObjectOpen(&out.writer, Line{
                .seq = seq,
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
            if (out.written().len > self.config.max_record_bytes) return error.RecordTooLarge;

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
            self.record_hint = stored.len;
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
        fn publish(self: *Self, item: Built) bool {
            self.seq = item.seq;
            if (!self.keepsRecords()) return false;
            const record = item.record.?;
            self.tail.appendAssumeCapacity(.{ .record = record, .arena = item.arena.? });
            for (self.sinks.items) |sink| sink.f(sink.ctx, record);
            return true;
        }

        /// Read the newest records back into the tail, and check that they say
        /// what the segment names say.
        fn fillTail(self: *Self, io: Io) OpenError!void {
            self.seq = self.log.lastSeq();
            var rebuilt: Tail = .{};
            errdefer rebuilt.deinit(self.gpa);
            const want = self.config.tail_records;
            const from = if (self.seq > want) self.seq - want else self.log.baseSeq();

            var scan = try self.log.scanFrom(io, from, .{ .may_write = true, .extent = .known });
            defer scan.deinit(io);

            var run: Continuity = .{ .cursor = from };
            while (try scan.next(io)) |line| {
                if (scan.takeBoundary()) |boundary| try run.beginSegment(boundary);
                _ = self.scratch.reset(.retain_capacity);
                const header = try parseHeader(self.scratch.allocator(), line);
                if (!try run.accept(header)) continue;

                const arena = try createArena(self.gpa);
                errdefer destroyArena(arena);
                const stored = try arena.allocator().dupe(u8, line);
                const record = try recordFrom(self.captureDecoder(), arena.allocator(), header, stored);
                try rebuilt.entries.ensureUnusedCapacity(self.gpa, 1);
                rebuilt.appendAssumeCapacity(.{ .record = record, .arena = arena });
                rebuilt.trim(self.config);
            }

            // Continuity belongs to the walk, not the cache: either tail
            // ceiling may evict even the newest record while it is read.
            if (run.expected) |next| {
                if (next != self.seq + 1) return error.DiscontinuousSeq;
            } else if (self.log.baseSeq() != self.seq) {
                return error.DiscontinuousSeq;
            }
            self.tail.deinit(self.gpa);
            self.tail = rebuilt;
        }

        /// Drop the oldest records until the tail is inside both of its
        /// ceilings — at least half of it at a time, so that keeping a tail
        /// costs a constant amount per append rather than a growing one.
        fn trimTail(self: *Self) void {
            self.tail.trim(self.config);
        }

        fn clearTail(self: *Self) void {
            self.tail.removePrefix(self.tail.entries.items.len);
        }

        /// Evict records whose segment retention just removed from the log.
        fn dropTailBefore(self: *Self, first_seq: u64) void {
            var drop: usize = 0;
            while (drop < self.tail.entries.items.len and self.tail.entries.items[drop].record.seq < first_seq) : (drop += 1) {}
            self.tail.removePrefix(drop);
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

        /// Called under the journal's lock.
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
            std.debug.assert(ev.from <= ev.to);
            std.debug.assert(ev.to <= line.len);
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

        fn readSnapshot(self: *Self, io: Io) OpenWithSnapshotError!?Snapshot {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();

            const Document = struct { seq: u64, state: []const u8 };
            const document = (self.readDocument(
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
