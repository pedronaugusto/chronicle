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
//! `switch` in the fold. A record's line is written and read by strand, which
//! writes the bytes `std.json` writes and reads what `std.json` reads; this
//! package keeps the lines.
//!
//! See `Journal` for the API, and README.md for the durability promises.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Log = @import("journal/Log.zig");
const strand = @import("journal/jsonl.zig").strand;
const facade = @import("journal/facade.zig");
const implementation = @import("journal.zig");

/// An event kept as its bytes: what a `migrate` hook is handed, what an
/// `unknown` arm of this type holds, and an `Event` of its own for a journal
/// that carries events it does not read. It is strand's, read back as a
/// slice of the record's line; `Raw.parse` reads it as a type.
pub const Raw = strand.Raw;

/// What `Journal.open` does with a final line the previous writer did not
/// finish — the normal shape of a crash during `append`.
pub const OnTruncated = Log.OnTruncated;

/// Whether a journal may be written to, and so whether it takes the lock.
pub const Access = Log.Access;

/// How often `append` makes the bytes it wrote durable. README.md states the
/// promise each level carries, per platform.
pub const Sync = Log.Sync;

/// The call a durable write makes on a platform.
pub const Flush = Log.Flush;

/// What `Options.sync = .always` issues here, which is what a returned
/// sequence number survives here. README.md's durability rules are the same
/// three answers in words.
pub const flush: Flush = Log.flush;

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
pub const Verify = implementation.Verify;

/// The name of the segment file whose first record is `base_seq`, relative to
/// the journal's directory. Exposed because a journal's directory is meant to
/// be read with `tail -f` and with your eyes.
pub fn segmentName(base_seq: u64) [Log.name_digits + segment_extension.len:0]u8 {
    return implementation.segmentName(base_seq);
}

/// The name of the index beside the segment `segmentName(base_seq)` names:
/// a cache of where its records are, which `open` rebuilds when it is gone
/// or does not describe the segment.
pub fn indexName(base_seq: u64) [Log.name_digits + index_extension.len:0]u8 {
    return implementation.indexName(base_seq);
}

/// The version stamped into the two documents that live beside the log: the
/// snapshot and a named reader's cursor. Neither is part of the log — one is
/// a copy of a fold and the other is a number a reader keeps — but both are
/// read back by this package, so both say which shape they are in and an
/// unknown one is `error.UnsupportedFormat` rather than a guess.
pub const document_format: u32 = implementation.document_format;

/// The CRC32C of the bytes a record's checksum covers: its line up to, but not
/// including, the `,"c":` that carries the checksum.
///
/// `append` writes it and every read verifies it. It is public so that a tool
/// reading a segment with something other than this package can check one.
pub fn checksum(covered: []const u8) u32 {
    return implementation.checksum(covered);
}

/// Where a `Replay` got to, for the next one to start from: what
/// `Replay.position` hands back and `Journal.replayAt` takes.
///
/// A reader that follows a log -- one that wakes at every append and hands
/// on what is new -- would otherwise start each pass with `replay(cursor)`,
/// which lands on the index entry at or before the cursor and reads its way
/// forward to it. A position goes straight to the byte after the last
/// record read, in the file it was read from.
///
/// It is plain data: kept between passes, handed to another task, or used
/// with another `Journal` on the same directory. It names a record as well as
/// a place, and `replayAt` reads that record back before it goes on, so a
/// position into bytes that are not the ones it was taken from -- a
/// `compact`, a `truncateAfter`, a `dropSegmentsBefore` since -- is
/// `error.StalePosition`, never records from the wrong place.
pub const Position = implementation.Position;

/// An append-only log of `Event` values.
///
/// The returned type owns a directory, the newest segment's files, an advisory
/// lock, a bounded tail of records in memory and one mutex. Create it with
/// `open` or `openWithSnapshot` and release it with `close`, or with the
/// best-effort `deinit` where an error cannot be returned.
///
/// Construction returns a pointer to an opaque owner. Its state stays at one
/// address; keep and pass that pointer, and release the owner exactly once.
/// The allocator must outlive it. Finish every replay and tailer operation
/// before closing the journal; release replays and tailers first.
///
/// `Event` must round-trip through `std.json`: `std.json.Stringify.value` must
/// accept it and `std.json.parseFromSlice` must read back what was written.
/// strand does both, in `std.json`'s bytes and with its answers. A tagged
/// union of structs is the expected shape; a `strand.Raw` is an event kept as
/// its bytes, read back as a slice of the line.
pub fn Journal(comptime Event: type) type {
    return opaque {
        const Self = @This();
        const State = implementation.Journal(Event);

        fn inner(self: *Self) *State {
            return @ptrCast(@alignCast(self)); // safe: open returns this allocated State, retained until close or deinit.
        }
        fn from(state: *State) *Self {
            return @ptrCast(state); // safe: hides the same stable State allocation without copying it.
        }
        /// One entry of the log, as held in memory.
        ///
        /// Every slice in a record — `bytes`, and anything `event` points at —
        /// belongs to the `Batch` or `Replay` that produced it, or lasts for
        /// the call to a `Sink`. See `Batch.deinit` and `Replay.next`.
        pub const Record = State.Record;

        /// An owned copy of the records after a cursor that memory still holds.
        /// Every record, its bytes and everything its event points at belongs
        /// to this batch, independent of the journal and its lifetime.
        /// Keep its pointer and release the owner exactly once with `deinit`,
        /// before the allocator passed to `copySince`. Every pointer alias and
        /// record borrow becomes invalid on release.
        pub const Batch = opaque {
            fn inner(batch: *const Batch) *const State.Batch {
                return @ptrCast(@alignCast(batch)); // safe: copySince returns this allocated State.Batch, retained until deinit.
            }
            fn from(batch: *State.Batch) *Batch {
                return @ptrCast(batch); // safe: hides the same stable State.Batch allocation without copying it.
            }

            /// The records, oldest first. Empty when the cursor is caught up.
            /// The slice and every record's referenced data last until `deinit`.
            pub fn records(batch: *const Batch) []const Record {
                return batch.inner().records;
            }

            /// Whether no records between the cursor and the newest sequence
            /// known at the time of the copy are missing. False means the tail
            /// no longer reaches back that far: use `replay` or `subscribeFrom`.
            pub fn complete(batch: *const Batch) bool {
                return batch.inner().complete;
            }

            /// Release the owner, every record and all its referenced data.
            /// Call only after every user of this batch has finished.
            pub fn deinit(batch: *Batch) void {
                const state: *State.Batch = @ptrCast(@alignCast(batch)); // safe: this is the live allocation returned by copySince, released exactly once here.
                state.deinit();
            }
        };

        /// One record for `appendAll`: what `append` takes as two arguments.
        pub const Entry = State.Entry;

        /// A fold, called once per record: for the records the journal replays
        /// when it subscribes, and then for each one appended, in sequence
        /// order, with the journal's lock held.
        ///
        /// The callback must not call back into the journal, and must not
        /// retain the `Record` or anything inside it past the call.
        pub const Sink = State.Sink;

        /// What a `migrate` hook may fail with. `Unmigratable` means the hook
        /// knows the version and refuses it; it reaches the caller unchanged.
        pub const MigrateError = State.MigrateError;

        /// Translates a record written at an older schema version into the
        /// current `Event`.
        ///
        /// `arena` is the arena that owns the record being built, and `event`
        /// is the record's `ev` member as its bytes, checked as JSON: a slice
        /// of the record's line, which lasts as long as the record does.
        /// `event.parse(Old, arena, .{})` reads the old shape as a type,
        /// with its strings borrowed from the line where they need no
        /// unescaping. What the hook allocates from `arena` — that parse, a
        /// string put together, a slice of the new form — lasts exactly as
        /// long as the record does, and so does anything in `event` the
        /// returned `Event` borrows. Nothing needs freeing: the arena goes
        /// with the record.
        pub const Migrate = State.Migrate;

        /// How a journal is opened. Every field has a default; the defaults are
        /// the durable, forgiving ones.
        pub const Options = State.Options;

        /// A snapshot read back from disk.
        ///
        /// `state` is the byte string that was passed to `snapshot`, and `seq`
        /// is the journal's newest sequence number at that moment: fold `state`
        /// into your state and then replay only the records after `seq`, which
        /// is what `subscribeFrom` and `copySince` take.
        ///
        /// `state` is the caller's, from the allocator `openWithSnapshot` was
        /// given; release it with `Snapshot.deinit` when the fold has been
        /// restored from it.
        pub const Snapshot = State.Snapshot;

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
        /// * `BrokenBatch` — the records of an atomic batch do not run from
        ///   its first to its last, one after another, inside one segment:
        ///   a batch that was cut or interleaved anywhere but at the end of
        ///   the newest segment, which `open` drops whole.
        /// * `RecordTooLarge` — a line runs past `Options.max_record_bytes`
        ///   without a newline, so it is not read into memory to find out.
        /// * `UnsupportedFormat` — a segment file's first line is not one
        ///   this version writes. The framing carries its version there, so
        ///   a file from another one is refused by name and never read as if
        ///   it were records.
        /// * `NewerSchema` — a record was written at a version above
        ///   `Options.schema_version`. This process is the old one.
        /// * `OlderSchema` — a record was written at a version below
        ///   `Options.schema_version` and there is neither a `migrate` hook nor
        ///   an `unknown` arm to receive it.
        /// * `Unmigratable` — the `migrate` hook refused a record.
        ///
        /// And what reading a file can fail with: `OutOfMemory`, `Canceled`,
        /// and the errors of opening, reading and seeking a file.
        pub const ReadError = State.ReadError;

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
        pub const OpenError = State.OpenError;

        /// `OpenError`, plus `CorruptSnapshot` for a snapshot file that is not
        /// the object `snapshot` writes, and `SnapshotTooLarge` for one
        /// longer than `Options.max_snapshot_bytes`. A missing snapshot file
        /// is not an error; it yields `Opened.snapshot == null`.
        pub const OpenWithSnapshotError = State.OpenWithSnapshotError;

        /// Errors from `append`.
        ///
        /// * `PersistenceFailed` — an earlier `append` could not reach the
        ///   disk. Later appends are latched until `reconcile` establishes
        ///   whether the attempted record survived and restores the sequence.
        /// * `NotRoundTrippable` — the event was written to JSON but did not
        ///   parse back as `Event` the way every read parses it — one that
        ///   writes a member it does not read back included. Nothing was
        ///   written to the file.
        /// * `SequenceExhausted` — the newest sequence number is
        ///   `maxInt(i64)`, and one more could not be read back, because a
        ///   sequence number is a JSON integer.
        /// * `WriteFailed` — a custom stringify hook refused the event, or
        ///   writing or flushing the file failed. A hook refusal changes no
        ///   file and does not latch persistence failure.
        /// * `RecordTooLarge` — the line the record would be written as is
        ///   longer than `Options.max_record_bytes`. Nothing was written.
        /// * `ReadOnly` — the journal was opened with `Access.read`.
        pub const AppendError = State.AppendError;

        /// `AppendError`, and `WrongExpectedSeq`: the newest record is not the
        /// one the caller expected, so nothing was written. `Expected.found`
        /// says which it is.
        pub const AppendIfError = State.AppendIfError;

        /// What `appendIf` and `appendAllIf` expect of the journal: the
        /// sequence number its newest record must still have, and where to
        /// say what it has instead.
        pub const Expected = State.Expected;

        /// How `appendAll` commits a batch: `.group`, one sync and a crash may
        /// leave a prefix, or `.atomic`, one sync and all or nothing.
        pub const Commit = State.Commit;

        /// Errors from reconciling the journal after a persistence failure.
        pub const ReconcileError = State.ReconcileError;

        /// Errors from `replay`, and from the `Replay` it returns.
        pub const ReplayError = State.ReplayError;

        /// Copying the tail may be canceled at the lock or run out of memory.
        pub const CopyError = State.CopyError;

        /// `replayAt`'s errors: `replay`'s, and a position that no longer
        /// names the record it was taken after.
        pub const ReplayAtError = State.ReplayAtError;

        /// Errors from `seqAtOrAfter`, which may have to rebuild an index
        /// before it can answer and so can fail at everything `open` can.
        pub const SeekError = State.SeekError;

        /// Errors from `subscribe` and `subscribeFrom`, which replay the
        /// records a cursor has missed before they register the sink:
        /// `ReplayError`, `Canceled`, and `HistoryDropped` — the cursor is
        /// older than the oldest record the log still holds, because a
        /// `compact` or `dropSegmentsBefore` removed the records after it.
        /// Nothing was registered.
        pub const SubscribeError = State.SubscribeError;

        /// Errors from `snapshot`.
        pub const SnapshotError = State.SnapshotError;

        /// Errors from durably closing the active segment.
        pub const CloseError = State.CloseError;

        /// Errors from `tailer` and from a `Tailer`'s own calls.
        ///
        /// * `InvalidName` — a tailer's name becomes a filename beside the
        ///   log, so it has to be one path component of lowercase letters,
        ///   digits, `-` and `_`, and no more than 64 of them. Lowercase,
        ///   because macOS and Windows fold case by default and two names
        ///   differing only in it would share one cursor there.
        /// * `CorruptCursor` — the cursor file is not the object `commit`
        ///   writes. A missing one is not an error; it is a cursor of zero.
        /// * `UnsupportedFormat` — the cursor file was written in a document
        ///   format this version does not read.
        ///
        /// And what writing the cursor file can fail with.
        pub const TailerError = State.TailerError;

        /// Errors from `compact`. It re-reads the journal it has just written,
        /// so every `OpenError` is possible.
        pub const CompactError = State.CompactError;

        /// Errors from `dropSegmentsBefore`.
        pub const DropError = State.DropError;

        /// Errors from `backup`.
        ///
        /// * `BackupInPlace` — the destination is the journal's own directory,
        ///   by whatever path it was named (a symbolic link to it included),
        ///   which would have meant copying its segments over themselves.
        pub const BackupError = State.BackupError;

        /// Errors from `truncateAfter`.
        ///
        /// * `SeqTooOld` — the log no longer holds a record at or before the
        ///   cut, so truncating to it would claim a history that has already
        ///   been dropped.
        pub const TruncateError = State.TruncateError;

        /// The journal's recovery and persistence state at one instant.
        pub const Status = State.Status;

        /// What the log is made of, in numbers.
        pub const Stats = State.Stats;

        /// A named reader and where it has got to, as the directory holds
        /// it: the pair `readers` lists, without opening a `Tailer`.
        pub const Reader = State.Reader;

        /// An owned list of named readers and their committed cursors.
        /// Independent of the journal and its lifetime. Keep its pointer and
        /// release the owner exactly once with `deinit`, before the allocator
        /// passed to `open`. Every pointer alias and item borrow becomes
        /// invalid on release.
        pub const Readers = opaque {
            fn inner(list: *const Readers) *const State.Readers {
                return @ptrCast(@alignCast(list)); // safe: readers returns this allocated State.Readers, retained until deinit.
            }
            fn from(list: *State.Readers) *Readers {
                return @ptrCast(list); // safe: hides the same stable State.Readers allocation without copying it.
            }

            /// The readers at the time of the listing, in directory order.
            /// The slice and names last until `deinit`.
            pub fn items(list: *const Readers) []const Reader {
                return list.inner().items;
            }

            /// Release the owner, the list and every reader name together.
            /// Call only after every user of this list has finished.
            pub fn deinit(list: *Readers) void {
                const state: *State.Readers = @ptrCast(@alignCast(list)); // safe: this is the live allocation returned by readers, released exactly once here.
                state.deinit();
            }
        };

        /// The journal and the caller-owned snapshot beside it, if any.
        pub const Opened = struct {
            journal: *Self,
            snapshot: ?Snapshot,
        };
        /// Open the journal directory at `path`, creating it if it is not
        /// there, and read back the newest records.
        ///
        /// The sequence number continues from the last record, so a restart
        /// never reuses a number. A final record the previous writer did not
        /// finish -- one with no newline, or one whose newline reached the
        /// disk without all of its bytes -- is handled per
        /// `Options.on_truncated`; with the default it is dropped, the
        /// segment is shortened to the last whole record, and
        /// the byte count is reported by `status(io).dropped_bytes`, so the next `append` writes
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
        pub fn open(gpa: Allocator, io: Io, path: []const u8, settings: Options) OpenError!*Self {
            return from(try State.open(gpa, io, path, settings));
        }

        /// `open`, plus the snapshot written beside the journal by a previous
        /// `snapshot` call, if there is one.
        ///
        /// A caller that restores `Opened.snapshot.?.state` into its fold then
        /// needs only the records after `Opened.snapshot.?.seq`; hand that
        /// number to `subscribeFrom`. The state is the caller's to free.
        pub fn openWithSnapshot(gpa: Allocator, io: Io, path: []const u8, settings: Options) OpenWithSnapshotError!Opened {
            const opened = try State.openWithSnapshot(gpa, io, path, settings);
            return .{ .journal = from(opened.journal), .snapshot = opened.snapshot };
        }

        /// Flush and durably close the active segment, then release the lock
        /// and every allocation. The journal is consumed even when an error
        /// is returned. Call only after every caller and replay has stopped;
        /// owned batches, reader lists and snapshot state remain valid.
        pub fn close(self: *Self, io: Io) CloseError!void {
            return State.close(self.inner(), io);
        }

        /// Best-effort fallback for scopes that cannot return a close error.
        /// Prefer `close` when `.on_segment` relies on shutdown for its final
        /// durable write. Call only after every caller and replay has stopped;
        /// owned batches, reader lists and snapshot state remain valid.
        pub fn deinit(self: *Self, io: Io) void {
            return State.deinit(self.inner(), io);
        }

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
        /// A cancel is not a failure to reach the disk. One that arrives while
        /// the call waits for the lock returns `error.Canceled` with nothing
        /// written; once the record is being written it runs to its end, and
        /// the cancel is the caller's next cancelation point's to report.
        ///
        /// Safe to call from any task or thread.
        pub fn append(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            return State.append(self.inner(), io, at, event);
        }

        /// `append`, with the record's durability left to the next flush:
        /// the record is written, handed to the operating system and
        /// published — the sinks called, the waiters woken — at once, and
        /// made durable with whatever makes the file durable next: an
        /// `append` or `appendAll` under `Options.sync = .always`, a
        /// rotation, a snapshot, `close`. This is group commit asked for
        /// record by record, where the caller knows which of its records
        /// must be on the disk before it acts and which may ride with the
        /// next one that must.
        ///
        /// What it promises is what `.on_segment` promises for every
        /// record: a process crash, a kill included, loses nothing, since
        /// the operating system has the bytes; a power cut may lose the
        /// deferred records written since the last flush. Only those: the
        /// file is written in order and a flush is of the whole file, so a
        /// record that is durable has every record before it durable too,
        /// and what a power cut can take is a suffix, never a gap.
        ///
        /// Under `.on_segment` and `.never` it is `append`.
        ///
        /// Safe to call from any task or thread.
        pub fn appendDeferred(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            return State.appendDeferred(self.inner(), io, at, event);
        }

        /// Write every entry, in order, under one `fsync`, and return the
        /// sequence number of the last one.
        ///
        /// The records go into the log one line each, and the whole batch is
        /// made durable once at the end instead of once per record — so a
        /// batch of a thousand costs one `fsync` under `Options.sync = .always`
        /// rather than a thousand. What a crash inside the batch leaves is
        /// what `commit` says:
        ///
        /// * `.group` — a **prefix** of the batch, with a torn final line at
        ///   worst, which is the shape a crash inside a single `append` leaves
        ///   and is repaired the same way.
        /// * `.atomic` — the whole batch or none of it. Every record of a
        ///   batch of more than one names the batch's first and last sequence
        ///   numbers (`"bf"` and `"bl"`, before `"ev"`), the batch is kept in
        ///   one segment, past `Options.max_segment_bytes` if it has to be,
        ///   and an open that finds the log ending inside a batch drops the
        ///   batch whole, as it drops a torn line: `Options.on_truncated`
        ///   says whether it may. A reader beside the writer reads a batch
        ///   only once its last record is there, and a replay checks that
        ///   every batch it walks is whole. Old journals, and records written
        ///   by `.group`, have no batch members and read as they always did.
        ///
        /// Nothing is published unless the bytes reached the disk: no record
        /// is added to the tail and no sink is called until the `fsync`
        /// returns. A failure part-way through latches the journal exactly as
        /// `append`'s does, and the disk may then hold some of the batch;
        /// `reconcile` or reopening reads back what survived, which for an
        /// `.atomic` batch is all of it or none.
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
        pub fn appendAll(self: *Self, io: Io, entries: []const Entry, commit: Commit) AppendError!u64 {
            return State.appendAll(self.inner(), io, entries, commit);
        }

        /// `append`, only if the newest record is still `expected.last`:
        /// optimistic concurrency, as an event store's expected revision. A
        /// writer that folds the journal, decides, and appends what it decided
        /// passes the sequence number it folded to, and a writer that lost the
        /// race to another gets `error.WrongExpectedSeq`, with the newest
        /// sequence number in `expected.found`, and nothing written — fold the
        /// records it missed and decide again. The comparison and the append
        /// are one step under the journal's lock, so of several writers
        /// expecting the same sequence number exactly one appends.
        ///
        /// A journal that refuses every append — opened for reading, latched
        /// by a failed write — says that first.
        ///
        /// Safe to call from any task or thread.
        pub fn appendIf(self: *Self, io: Io, expected: Expected, at: i64, event: Event) AppendIfError!u64 {
            return State.appendIf(self.inner(), io, expected, at, event);
        }

        /// `appendAll`, only if the newest record is still `expected.last`:
        /// `appendIf` for a batch. An empty batch checks the expectation and
        /// writes nothing.
        ///
        /// Safe to call from any task or thread.
        pub fn appendAllIf(self: *Self, io: Io, expected: Expected, entries: []const Entry, commit: Commit) AppendIfError!u64 {
            return State.appendAllIf(self.inner(), io, expected, entries, commit);
        }

        /// Re-read the journal after an append persistence failure and report
        /// the newest sequence number that actually survived.
        ///
        /// A failed flush or `fsync` cannot say whether the operating system
        /// accepted the complete line before reporting the error. Until this
        /// call succeeds, appends stay latched with `error.PersistenceFailed`.
        /// On success the tail is rebuilt, the latch is cleared, and the
        /// caller can compare the returned sequence with the attempted one
        /// before deciding whether to retry it. A record that survived is
        /// handed to every subscribed sink and wakes every `waitPast`, as
        /// an append would have.
        pub fn reconcile(self: *Self, io: Io) ReconcileError!u64 {
            return State.reconcile(self.inner(), io);
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
            return State.nudge(self.inner(), io);
        }

        /// Copy the records after `cursor` that are in the tail, under the
        /// journal's lock. Pass zero to copy the whole tail.
        ///
        /// A cursor at or beyond the newest sequence yields an empty, complete
        /// batch. A cursor older than the tail yields the whole tail with
        /// `Batch.complete()` false: use `replay` or `subscribeFrom` for the gap.
        /// Waiting and reading are separate: `waitPast` returns a sequence,
        /// then this call copies what is still held when it takes the lock.
        ///
        /// The batch owns everything it returns through `gpa`; release it
        /// with `Batch.deinit`. Events and all their storage are copied through
        /// strand without calling parse, stringify or migration hooks. Events
        /// must be finite trees of data accepted by `strand.copyOwned`. The exact
        /// stored bytes and original schema versions are preserved separately.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn copySince(self: *Self, gpa: Allocator, io: Io, cursor: u64) CopyError!*Batch {
            return Batch.from(try State.copySince(self.inner(), gpa, io, cursor));
        }

        /// Block until there is a record after `cursor`, or until `nudge`, then
        /// return the newest sequence number known to the journal.
        ///
        /// A nudge may return a number at or below the cursor. No records are
        /// returned: use `copySince`, `replay` or a subscription to read them.
        /// The tail may move between waiting and reading; `Batch.complete()`
        /// tells a reader whether it needs the disk to cover the gap.
        /// Safe to call from any task or thread, including several at once.
        pub fn waitPast(self: *Self, io: Io, cursor: u64) Io.Cancelable!u64 {
            return State.waitPast(self.inner(), io, cursor);
        }

        /// A walk over every record after `cursor`, read from the disk.
        ///
        /// This is how a fold covers a history longer than memory: record data
        /// is one record and one read buffer at a time. It also snapshots two
        /// integers per segment it will cross. Release it with `deinit`.
        ///
        /// It reads the segments as they were when it was made. A `compact` or
        /// a `dropSegmentsBefore` beside it may leave it reading a file that
        /// has gone, which it reports as an error rather than as wrong records.
        ///
        /// Records appended while it runs may or may not appear: a `Replay`
        /// does not hold the journal's lock. `subscribeFrom` is the version
        /// that misses nothing.
        ///
        /// A cursor below `oldestSeq() - 1` starts at the oldest record the
        /// log holds: what a `compact` or `dropSegmentsBefore` removed is
        /// not there to read. Compare the first record's `seq` with
        /// `cursor + 1` where a gap matters; `subscribeFrom` refuses one.
        ///
        /// It writes nothing. A segment whose index is missing or stale is
        /// walked from its start rather than indexed on the way, because
        /// building an index is left to `open`, `refresh` and `seqAtOrAfter`.
        /// Choosing the scan holds the lock: the segment inventory, cached
        /// index handle and live index buffer belong to the journal. The
        /// returned walk owns its scan metadata and reads without that lock.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn replay(self: *Self, io: Io, cursor: u64) ReplayError!*Replay {
            return Replay.from(try State.replay(self.inner(), io, cursor));
        }

        /// A walk over every record after `position`, starting at the byte
        /// after the last record the walk that handed it back had read.
        ///
        /// This is `replay` for a reader that comes back: a follower that
        /// wakes at every append keeps the position its last pass ended at
        /// and starts the next pass there, in the file and at the offset it
        /// stopped, instead of seeking by its cursor and reading its way
        /// forward to it. The records are the ones `replay(position.cursor)`
        /// gives, checked the same way, the chain included: the first one is
        /// checked against the last one the position names.
        ///
        /// That record is read back before anything else, and must be where
        /// the position says, with the sequence number and checksum it says.
        /// When it is not -- its segment was rewritten by a `compact` or
        /// dropped, the log was cut by `truncateAfter` and written again --
        /// the answer is `error.StalePosition`, and a `replay` from
        /// `position.cursor` is the way on (compare `oldestSeq` with the cursor
        /// to learn whether records were dropped before the reader had them).
        /// A position that names no record is `replay(position.cursor)`.
        ///
        /// A record the writer has not finished is not read, and a walk that
        /// stops in front of one hands back a position in front of it: a
        /// walk from there reads it once it is whole. Records appended in one
        /// `appendAll` are read as the walk finds them, all of them once the
        /// batch is committed.
        ///
        /// The segments it will cross are decided under the journal's lock,
        /// from what is committed then; the walk itself reads without it.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn replayAt(self: *Self, io: Io, position: Position) ReplayAtError!*Replay {
            return Replay.from(try State.replayAt(self.inner(), io, position));
        }

        /// Read every record of every segment back, through the checks a
        /// replay makes — the checksum, the envelope, the schema version and
        /// the sequence — and report how many there were.
        ///
        /// This is what `Options.verify = .full` runs at `open`, and it is
        /// what a caller runs on a journal it has reason to doubt. It costs
        /// the log rather than one segment. The scan is chosen under the
        /// lock and read without it; retention beside it may remove a file
        /// it needs, which is reported as an error.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn verify(self: *Self, io: Io) ReplayError!u64 {
            return State.verify(self.inner(), io);
        }

        /// The newest sequence number, or zero on an empty journal.
        ///
        /// Safe to call from any task or thread.
        pub fn lastSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            return State.lastSeq(self.inner(), io);
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
            return State.seqAtOrAfter(self.inner(), io, at);
        }

        /// Read the directory again: pick up segments another process has
        /// added, and rebuild the tail from what is there now.
        ///
        /// This is how a `.read` journal tails a writer in another process. A
        /// `Replay` already reads to the end of every segment it knows about,
        /// so this is what a reader needs when the writer has *rotated*. It
        /// costs a walk of the newest segment, as `open` does.
        ///
        /// Records it finds after the newest one this journal knew are
        /// handed to every subscribed sink, and a `waitPast` they move past
        /// returns: a `.read` journal's folds and waiters follow the writer
        /// through `refresh` the way a writer's follow its appends.
        ///
        /// Safe to call from any task or thread.
        pub fn refresh(self: *Self, io: Io) OpenError!void {
            return State.refresh(self.inner(), io);
        }

        /// How many segments the log is spread over. One for a young journal;
        /// it grows by one every `Options.max_segment_bytes`.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn segmentCount(self: *Self, io: Io) Io.Cancelable!usize {
            return State.segmentCount(self.inner(), io);
        }

        /// The oldest sequence number the log still holds — 1 until a `compact`
        /// or a `dropSegmentsBefore` drops a prefix, and one past `lastSeq` on
        /// a log with no records in it. Compare it against a cursor to see what
        /// a reader has missed for good.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn oldestSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            return State.oldestSeq(self.inner(), io);
        }

        /// Copy the configuration supplied at open under the journal's lock.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn options(self: *Self, io: Io) Io.Cancelable!Options {
            return State.options(self.inner(), io);
        }

        /// Copy the recovery and persistence state under the journal's lock.
        /// A later write or reconciliation may change it.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn status(self: *Self, io: Io) Io.Cancelable!Status {
            return State.status(self.inner(), io);
        }

        /// `Stats`, read off the segments the journal already knows about: no
        /// file is opened and nothing is scanned.
        ///
        /// Safe to call from any task or thread.
        pub fn stats(self: *Self, io: Io) Io.Cancelable!Stats {
            return State.stats(self.inner(), io);
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
            return State.subscribe(self.inner(), io, sink);
        }

        /// `subscribe`, starting after `cursor` — the sequence number of a
        /// snapshot the fold has already been restored from.
        ///
        /// A cursor below `oldestSeq() - 1` is `error.HistoryDropped`: the
        /// records after it are gone, and a fold restored to it would skip
        /// them without knowing. A caller who accepts the gap starts from
        /// `oldestSeq() - 1`; zero means everything the log holds.
        ///
        /// Records the tail no longer holds are streamed from the disk one at a
        /// time, so a fold over a year of records costs the largest record and
        /// not the year. The journal's lock is held for the whole replay: an
        /// `append` from another task waits for it, which is what makes the
        /// hand-over from the disk to the live records seamless.
        pub fn subscribeFrom(self: *Self, io: Io, sink: Sink, cursor: u64) SubscribeError!void {
            return State.subscribeFrom(self.inner(), io, sink, cursor);
        }

        /// `subscribe` for several folds at once, over one pass of the log.
        pub fn subscribeAll(self: *Self, io: Io, sinks: []const Sink) SubscribeError!void {
            return State.subscribeAll(self.inner(), io, sinks);
        }

        /// Register every fold in `sinks` and hand each of them every record
        /// after `cursor`, reading the disk once for all of them.
        ///
        /// Subscribing five folds one at a time reads the log five times: each
        /// call opens its own walk, verifies every checksum again and parses
        /// every event again. This does that work once and calls each sink per
        /// record; the callbacks add only their own work.
        ///
        /// It is one call under one lock, so it is also the way to start
        /// several folds at the same record: a record appended beside it lands
        /// in all of them or in none of them, never in some.
        ///
        /// The sinks are registered in the order given and are called in that
        /// order for every record afterwards.
        pub fn subscribeAllFrom(self: *Self, io: Io, sinks: []const Sink, cursor: u64) SubscribeError!void {
            return State.subscribeAllFrom(self.inner(), io, sinks, cursor);
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
            return State.unsubscribe(self.inner(), io, sink);
        }

        /// Every named reader that has committed a cursor beside this log,
        /// and the number each of them last committed.
        ///
        /// A cursor file is written by whoever holds the name, in whatever
        /// process; this reads the directory rather than any register this
        /// journal keeps, so a reader in another process is in the list.
        ///
        /// The list owns its items and names through `gpa`, as a batch from
        /// `copySince` does; release it with `Readers.deinit`. It remains
        /// valid after the journal closes.
        ///
        /// Safe to call from any task or thread.
        pub fn readers(self: *Self, gpa: Allocator, io: Io) TailerError!*Readers {
            return Readers.from(try State.readers(self.inner(), gpa, io));
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
            return State.minCursor(self.inner(), io);
        }

        /// Open the named reader `name`, reading back the cursor it last
        /// committed — zero if it has never committed one.
        ///
        /// The name becomes a filename beside the log, so it is one path
        /// component of lowercase letters, digits, `-` and `_`; anything else is
        /// `error.InvalidName`. Release the handle with `Tailer.deinit`, which
        /// leaves the cursor file where it is.
        ///
        /// Safe to call from any task or thread.
        pub fn tailer(self: *Self, io: Io, name: []const u8) TailerError!*Tailer {
            return Tailer.from(try State.tailer(self.inner(), io, name));
        }

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
            return State.snapshot(self.inner(), io, state_bytes);
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
        /// before the cut yields what is left, and `Batch.complete()` is how a
        /// reader notices.
        ///
        /// Safe to call from any task or thread.
        pub fn dropSegmentsBefore(self: *Self, io: Io, seq: u64) DropError!u64 {
            return State.dropSegmentsBefore(self.inner(), io, seq);
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
        /// A snapshot taken after `seq` describes records this cuts, so it is
        /// removed first; `openWithSnapshot` then finds none, and the fold
        /// replays from the start of the log.
        ///
        /// Owned batches remain valid; subscribed sinks are not called again.
        ///
        /// Safe to call from any task or thread.
        pub fn truncateAfter(self: *Self, io: Io, seq: u64) TruncateError!void {
            return State.truncateAfter(self.inner(), io, seq);
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
        /// Owned batches remain valid; subscribed sinks are not called again.
        ///
        /// Safe to call from any task or thread.
        pub fn compact(self: *Self, io: Io, keep_after_seq: u64) CompactError!void {
            return State.compact(self.inner(), io, keep_after_seq);
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
            return State.backup(self.inner(), io, dest);
        }

        /// What `replay` returns: an opaque, allocated walk over the log.
        /// Keep its pointer and release it exactly once, before the journal.
        pub const Replay = facade.ReplayOwner(State, Position);
        /// An opaque, allocated named reader and the cursor it has committed.
        /// Keep its pointer and release it exactly once, before the journal.
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
        pub const Tailer = facade.TailerOwner(State, Replay);
    };
}
