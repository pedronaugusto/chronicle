//! zjournal — an append-only, replayable event log.
//!
//! One JSON object per line, each carrying a sequence number, a timestamp and
//! a schema version:
//!
//! ```
//! {"seq":1,"at":1700000000000,"v":1,"ev":{"created":{"id":7}}}
//! {"seq":2,"at":1700000000100,"v":1,"ev":{"renamed":{"id":7,"to":"b"}}}
//! ```
//!
//! The file is the state. Any number of readers fold the same records into
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
const assert = std.debug.assert;

/// What `Journal.open` does with a final line the previous writer did not
/// finish — the normal shape of a crash during `append`.
pub const OnTruncated = enum {
    /// Report `error.TruncatedRecord` and leave the file exactly as found.
    fail,
    /// Drop the unterminated bytes, shorten the file to the last complete
    /// record, and report how many bytes went in `Journal.dropped_bytes`.
    drop,
};

/// Suffix of the snapshot file `Journal.snapshot` writes beside the journal.
pub const snapshot_suffix = ".snapshot";

/// Suffix of the file `Journal.compact` writes and then renames over the
/// journal. A file with this suffix left behind by a crash is stale and is
/// overwritten by the next `compact`; it is never read.
pub const compact_suffix = ".compact";

/// An append-only log of `Event` values.
///
/// The returned type owns a file, an arena holding every record read or
/// written since the last `compact`, and one mutex. Create it with `open` or
/// `openWithSnapshot` and release it with `deinit`.
///
/// `Event` must round-trip through `std.json`: `std.json.Stringify.value`
/// must accept it and `std.json.parseFromSlice` must read back what was
/// written. A tagged union of structs is the expected shape.
pub fn Journal(comptime Event: type) type {
    return struct {
        const Self = @This();

        /// The allocator every non-arena allocation comes from. Owned by the
        /// caller; the journal never outlives it.
        gpa: Allocator,
        /// Holds the bytes of every record and everything parsed out of them.
        /// Nothing in it is freed before `compact` or `deinit`, which is what
        /// makes a slice handed to a reader stay readable.
        arena: std.heap.ArenaAllocator,
        /// Reset once per record while reading the file back; never holds
        /// anything a caller can see.
        scratch: std.heap.ArenaAllocator,
        /// The options `open` was given, unchanged.
        options: Options,
        /// The journal's path, as given to `open`. Owned by the journal.
        path: []const u8,
        file: Io.File,
        writer: Io.File.Writer,
        write_buf: []u8,
        list: std.ArrayList(Record),
        sinks: std.ArrayList(Sink),
        mutex: Io.Mutex,
        changed: Io.Condition,
        /// Bumped by `nudge`: a wake with no record behind it.
        nudges: u64,
        /// The sequence number of the newest record. Zero on an empty journal.
        seq: u64,
        /// One below the sequence number of the oldest record still held.
        /// Zero until a `compact` drops a prefix.
        base_seq: u64,
        /// Set by the first `append` that could not reach the disk. Latched:
        /// see `AppendError.PersistenceFailed`.
        persistence_failed: bool,
        /// How many unterminated bytes `open` dropped from the end of the
        /// file. Zero unless a previous writer died mid-record.
        dropped_bytes: usize,
        /// Test seam. When true, `compact` writes its replacement file and
        /// then fails with `error.InterruptedForTest` instead of renaming it
        /// into place, so a suite can prove the write-then-rename ordering
        /// leaves the journal intact. Leave it false.
        fail_compact_before_rename: bool,

        /// One entry of the log, as held in memory.
        ///
        /// Every slice in a record — `bytes`, and anything `event` points at —
        /// lives in the journal's arena and stays valid until `compact` or
        /// `deinit`.
        pub const Record = struct {
            /// Position in the log. The first record of a journal that has
            /// never been compacted is 1, and it rises by one per record.
            seq: u64,
            /// Whatever the appender passed as `at`. zjournal never reads a
            /// clock; milliseconds since the Unix epoch is the intended unit.
            at: i64,
            /// The schema version this record was written at. Equal to the
            /// journal's `Options.schema_version` unless it was written by an
            /// older writer and read back through `Options.migrate` or the
            /// `unknown` arm.
            version: u32,
            /// The parsed event.
            event: Event,
            /// This record's exact line on disk, without the trailing
            /// newline. Appending it to a stream reproduces the durable form
            /// with no re-encoding.
            bytes: []const u8,
        };

        /// A fold, called once per record: for the records already on disk
        /// when it subscribes, and then for each one appended, in sequence
        /// order, with the journal's lock held.
        ///
        /// The callback must not call back into the journal, and must not
        /// retain the `Record` past `compact` or `deinit`.
        pub const Sink = struct {
            ctx: *anyopaque,
            f: *const fn (*anyopaque, Record) void,
        };

        /// What a `migrate` hook may fail with. `Unmigratable` means the hook
        /// knows the version and refuses it; it reaches the caller of `open`
        /// unchanged.
        pub const MigrateError = error{ OutOfMemory, Unmigratable };

        /// Translates a record written at an older schema version into the
        /// current `Event`.
        ///
        /// `value` is the record's `ev` member, parsed into the journal's
        /// arena: an `Event` returned by the hook may borrow from it.
        pub const Migrate = *const fn (from_version: u32, value: std.json.Value) MigrateError!Event;

        /// How a journal is opened. Every field has a default; the defaults
        /// are the durable, forgiving ones.
        pub const Options = struct {
            /// The version stamped into every record `append` writes, and the
            /// version records are expected to be at when read back.
            schema_version: u32 = 1,
            /// What to do with an unterminated final line.
            on_truncated: OnTruncated = .drop,
            /// Called for a record written at a version below
            /// `schema_version`. Without it, such a record becomes the
            /// `Event` arm named `unknown` if there is one, and
            /// `error.OlderSchema` if there is not.
            migrate: ?Migrate = null,
            /// Whether `append` calls `fsync` before it returns. With it off,
            /// a returned sequence number means the bytes reached the
            /// operating system, not the disk.
            fsync: bool = true,
            /// Size of the journal's write buffer. One `append` of a record
            /// larger than this costs an extra write syscall, nothing more.
            write_buffer_size: usize = 64 * 1024,
        };

        /// A snapshot read back from disk.
        ///
        /// `state` is the byte string that was passed to `snapshot`, and
        /// `seq` is the journal's newest sequence number at that moment: fold
        /// `state` into your state and then replay only the records after
        /// `seq`, which is what `subscribeFrom` and `since` take.
        ///
        /// `state` lives in the journal's arena: valid until `compact` or
        /// `deinit`.
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

        /// Errors from reading a journal file back.
        ///
        /// * `CorruptRecord` — a line is not a JSON object with the members
        ///   this format requires, or its `ev` does not parse as `Event`.
        /// * `TruncatedRecord` — the final line is unterminated and
        ///   `Options.on_truncated` is `.fail`.
        /// * `DiscontinuousSeq` — sequence numbers skip or repeat.
        /// * `NewerSchema` — a record was written at a version above
        ///   `Options.schema_version`. This process is the old one.
        /// * `OlderSchema` — a record was written at a version below
        ///   `Options.schema_version` and there is neither a `migrate` hook
        ///   nor an `unknown` arm to receive it.
        pub const OpenError = Allocator.Error || Io.Cancelable || MigrateError ||
            Io.File.OpenError || Io.File.StatError || Io.File.SetLengthError ||
            Io.File.ReadPositionalError ||
            error{ CorruptRecord, TruncatedRecord, DiscontinuousSeq, NewerSchema, OlderSchema };

        /// `OpenError`, plus `CorruptSnapshot` for a snapshot file that is not
        /// the object `snapshot` writes. A missing snapshot file is not an
        /// error; it yields `Opened.snapshot == null`.
        pub const OpenWithSnapshotError = OpenError || error{CorruptSnapshot};

        /// Errors from `append`.
        ///
        /// * `PersistenceFailed` — an earlier `append` could not reach the
        ///   disk. It is latched for the life of the journal, because a
        ///   reader must never see a record the disk does not have: once one
        ///   record is missing, every later one would be a lie about the
        ///   order. Reopen the journal to resume.
        /// * `NotRoundTrippable` — the event was written to JSON but did not
        ///   parse back as `Event`. Nothing was written to the file.
        pub const AppendError = Allocator.Error || Io.Cancelable || Io.Writer.Error ||
            Io.File.SyncError || error{ PersistenceFailed, NotRoundTrippable };

        /// Errors from `subscribe` and `subscribeFrom`.
        pub const SubscribeError = Allocator.Error || Io.Cancelable;

        /// Errors from `snapshot`.
        pub const SnapshotError = Allocator.Error || Io.Cancelable || Io.Writer.Error ||
            Io.File.OpenError || Io.File.SyncError || Io.Dir.RenameError;

        /// Errors from `compact`. It re-reads the journal it has just written,
        /// so every `OpenError` is possible; `InterruptedForTest` comes only
        /// from `fail_compact_before_rename`.
        pub const CompactError = OpenError || Io.Writer.Error || Io.File.SyncError ||
            Io.Dir.RenameError || error{ PersistenceFailed, InterruptedForTest };

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

        /// Open `path`, creating it if it is not there, and read back every
        /// record already in it.
        ///
        /// The sequence number continues from the last record, so a restart
        /// never reuses a number. A final line the previous writer did not
        /// finish is handled per `Options.on_truncated`; with the default it
        /// is dropped, the file is shortened to the last complete record, and
        /// the byte count lands in `dropped_bytes`, so the next `append`
        /// writes a well-formed line.
        ///
        /// `path` may be relative to the current directory or absolute. The
        /// whole file is read into memory.
        ///
        /// Release with `deinit`.
        pub fn open(gpa: Allocator, io: Io, path: []const u8, options: Options) OpenError!Self {
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            const write_buf = try gpa.alloc(u8, options.write_buffer_size);
            errdefer gpa.free(write_buf);

            const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
            errdefer file.close(io);

            var self: Self = .{
                .gpa = gpa,
                .arena = .init(gpa),
                .scratch = .init(gpa),
                .options = options,
                .path = owned_path,
                .file = file,
                .writer = file.writer(io, write_buf),
                .write_buf = write_buf,
                .list = .empty,
                .sinks = .empty,
                .mutex = .init,
                .changed = .init,
                .nudges = 0,
                .seq = 0,
                .base_seq = 0,
                .persistence_failed = false,
                .dropped_bytes = 0,
                .fail_compact_before_rename = false,
            };
            errdefer {
                self.arena.deinit();
                self.scratch.deinit();
            }
            try self.load(io);
            return self;
        }

        /// `open`, plus the snapshot written beside the journal by a previous
        /// `snapshot` call, if there is one.
        ///
        /// A caller that restores `Opened.snapshot.?.state` into its fold then
        /// needs only the records after `Opened.snapshot.?.seq`; hand that
        /// number to `subscribeFrom` or `since`.
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
            // leave the arena bookkeeping behind in the original.
            const found = try self.readSnapshot(io);
            return .{ .journal = self, .snapshot = found };
        }

        /// Flush, close the file and release every allocation. Every slice the
        /// journal ever handed out is invalid afterwards.
        pub fn deinit(self: *Self, io: Io) void {
            if (!self.persistence_failed) self.writer.interface.flush() catch {};
            self.file.close(io);
            self.sinks.deinit(self.gpa);
            self.gpa.free(self.write_buf);
            self.gpa.free(self.path);
            self.arena.deinit();
            self.scratch.deinit();
            self.* = undefined;
        }

        /// Serialise `event`, write it, make it durable, publish it.
        ///
        /// Returns the new record's sequence number. `at` is stored as given;
        /// zjournal never reads a clock.
        ///
        /// The record kept in memory is parsed back out of the bytes that were
        /// written, so it owns its own memory and is exactly what a reopen
        /// would produce: an `Event` whose slices point at a stack buffer is
        /// safe to append.
        ///
        /// Nothing is published unless the bytes reached the disk. If the
        /// write, the flush or the `fsync` fails, the error comes back, no
        /// record is added, no sink is called, and every later `append`
        /// returns `error.PersistenceFailed`.
        ///
        /// Safe to call from any task or thread.
        pub fn append(self: *Self, io: Io, at: i64, event: Event) AppendError!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.persistence_failed) return error.PersistenceFailed;

            const next = self.seq + 1;
            const line: Line = .{ .seq = next, .at = at, .v = self.options.schema_version, .ev = event };
            const encoded = try std.json.Stringify.valueAlloc(self.gpa, line, .{});
            defer self.gpa.free(encoded);

            const arena = self.arena.allocator();
            const stored = try arena.dupe(u8, encoded);
            const parsed = std.json.parseFromSliceLeaky(Line, arena, stored, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NotRoundTrippable,
            };
            // Reserve before writing: after the bytes are durable nothing may
            // fail, or the disk would hold a record memory does not.
            try self.list.ensureUnusedCapacity(arena, 1);

            {
                errdefer self.persistence_failed = true;
                try self.writer.interface.writeAll(stored);
                try self.writer.interface.writeByte('\n');
                try self.writer.interface.flush();
                if (self.options.fsync) try self.file.sync(io);
            }

            if (self.list.items.len == 0) self.base_seq = next - 1;
            self.list.appendAssumeCapacity(.{
                .seq = next,
                .at = at,
                .version = self.options.schema_version,
                .event = parsed.ev,
                .bytes = stored,
            });
            self.seq = next;
            const record = self.list.items[self.list.items.len - 1];
            for (self.sinks.items) |sink| sink.f(sink.ctx, record);
            self.changed.broadcast(io);
            return next;
        }

        /// Every record held in memory, oldest first.
        ///
        /// The slice is valid until `compact` or `deinit`, and its length
        /// grows with `append`. Call it from the task that appends, or under
        /// coordination of your own; `waitPast` is the equivalent that takes
        /// the journal's lock.
        pub fn records(self: *const Self) []const Record {
            return self.list.items;
        }

        /// The records after `cursor`, which may be none.
        ///
        /// A cursor is where a reader got to, so `since(0)` is everything and
        /// `since(lastSeq())` is nothing. A cursor from before a `compact` —
        /// or from a journal this process has not caught up with — yields
        /// what is still held rather than an error; compare `records()[0].seq`
        /// against the cursor to detect the gap.
        ///
        /// Same validity and same threading rule as `records`.
        pub fn since(self: *const Self, cursor: u64) []const Record {
            return self.list.items[self.sinceIndex(cursor)..];
        }

        /// Block until there is a record after `cursor`, or until `nudge`,
        /// then return `since(cursor)`.
        ///
        /// The slice is valid until `compact` or `deinit`; its length is a
        /// snapshot taken under the lock, so it does not grow under the
        /// reader. A reader that waits again passes the sequence number of
        /// the last record it handled.
        ///
        /// Safe to call from any task or thread, including several at once.
        pub fn waitPast(self: *Self, io: Io, cursor: u64) Io.Cancelable![]const Record {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            const nudged = self.nudges;
            while (self.seq <= cursor and self.nudges == nudged) try self.changed.wait(io, &self.mutex);
            return self.list.items[self.sinceIndex(cursor)..];
        }

        /// Wake every `waitPast` with no new record — a shutdown, or
        /// something that moved beside the log.
        ///
        /// A nudge reaches the readers that are waiting when it happens and
        /// is not remembered for one that arrives afterwards, so a shutdown
        /// that must reach every reader sets its own flag first and nudges
        /// until the readers are gone.
        ///
        /// Safe to call from any task or thread.
        pub fn nudge(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.nudges +%= 1;
            self.changed.broadcast(io);
        }

        /// The newest sequence number, or zero on an empty journal.
        ///
        /// Safe to call from any task or thread.
        pub fn lastSeq(self: *Self, io: Io) Io.Cancelable!u64 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.seq;
        }

        /// Register a fold and hand it every record the journal holds, then
        /// every record appended afterwards.
        ///
        /// A fold built this way is built the same way whether the records
        /// came off the disk or arrived live, which is the point.
        ///
        /// The sink is called with the journal's lock held and lives until
        /// `deinit`; there is no unsubscribe.
        pub fn subscribe(self: *Self, io: Io, sink: Sink) SubscribeError!void {
            return self.subscribeFrom(io, sink, 0);
        }

        /// `subscribe`, starting after `cursor` — the sequence number of a
        /// snapshot the fold has already been restored from.
        pub fn subscribeFrom(self: *Self, io: Io, sink: Sink, cursor: u64) SubscribeError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try self.sinks.append(self.gpa, sink);
            for (self.list.items[self.sinceIndex(cursor)..]) |record| sink.f(sink.ctx, record);
        }

        /// Write `state_bytes` and the current sequence number to
        /// `<path>` ++ `snapshot_suffix`, replacing any snapshot there.
        ///
        /// `state_bytes` is opaque to zjournal: whatever your fold serialises
        /// to. It is stored base64-encoded in a JSON object, so the snapshot
        /// file is text however binary the state is.
        ///
        /// The replacement is written to a neighbouring temporary file,
        /// flushed and `fsync`ed, and then renamed over the destination, so a
        /// reader never sees a half-written snapshot. A snapshot is only ever
        /// an optimisation: deleting it costs replay time and nothing else.
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

            const final = try self.suffixedPath(snapshot_suffix);
            defer self.gpa.free(final);
            const temporary = try self.suffixedPath(snapshot_suffix ++ ".tmp");
            defer self.gpa.free(temporary);

            errdefer deletePath(io, temporary) catch {};
            try writeFileDurably(io, temporary, document);
            try Io.Dir.cwd().rename(temporary, .cwd(), final, io);
        }

        /// Rewrite the journal keeping only the records after
        /// `keep_after_seq`, and re-read it.
        ///
        /// The newest record is always kept, whatever `keep_after_seq` says,
        /// so the sequence number survives a reopen: a journal compacted to
        /// nothing would start counting from one again and two records would
        /// share a number.
        ///
        /// Kept records are copied byte for byte — no re-encoding, so a
        /// record read back through `migrate` or the `unknown` arm keeps the
        /// version and the payload it was written with.
        ///
        /// The replacement is written to `<path>` ++ `compact_suffix`,
        /// flushed and `fsync`ed, and then renamed over the journal. The
        /// rename is atomic, so an interrupted `compact` leaves either the
        /// whole old journal or the whole new one, never a partial file.
        ///
        /// Every slice the journal handed out before this call is invalid
        /// afterwards; subscribed sinks are not called again.
        ///
        /// Safe to call from any task or thread.
        pub fn compact(self: *Self, io: Io, keep_after_seq: u64) CompactError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.persistence_failed) return error.PersistenceFailed;

            const keep_after = if (self.seq == 0) 0 else @min(keep_after_seq, self.seq - 1);
            const temporary = try self.suffixedPath(compact_suffix);
            defer self.gpa.free(temporary);

            {
                const out = try Io.Dir.cwd().createFile(io, temporary, .{ .truncate = true });
                // Deleting comes after closing: an open file cannot be
                // removed on Windows, and errdefers run in reverse.
                errdefer deletePath(io, temporary) catch {};
                var closed = false;
                errdefer if (!closed) out.close(io);

                // `append` flushes every record, so the journal's own buffer
                // is empty and the replacement can borrow it.
                assert(self.writer.interface.end == 0);
                var buffer = out.writer(io, self.write_buf);
                for (self.list.items[self.sinceIndex(keep_after)..]) |record| {
                    try buffer.interface.writeAll(record.bytes);
                    try buffer.interface.writeByte('\n');
                }
                try buffer.interface.flush();
                try out.sync(io);
                out.close(io);
                closed = true;
            }

            if (self.fail_compact_before_rename) {
                deletePath(io, temporary) catch {};
                return error.InterruptedForTest;
            }
            try Io.Dir.cwd().rename(temporary, .cwd(), self.path, io);

            self.file.close(io);
            _ = self.arena.reset(.free_all);
            self.list = .empty;
            self.seq = 0;
            self.base_seq = 0;
            self.file = try Io.Dir.cwd().createFile(io, self.path, .{ .read = true, .truncate = false });
            self.writer = self.file.writer(io, self.write_buf);
            try self.load(io);
        }

        //====================================================================
        // Internals.
        //====================================================================

        fn sinceIndex(self: *const Self, cursor: u64) usize {
            if (cursor <= self.base_seq) return 0;
            return @intCast(@min(cursor - self.base_seq, self.list.items.len));
        }

        fn suffixedPath(self: *const Self, comptime suffix: []const u8) Allocator.Error![]u8 {
            return std.fmt.allocPrint(self.gpa, "{s}" ++ suffix, .{self.path});
        }

        /// Read the whole file back into `list`, repairing an unterminated
        /// final line, and leave the writer positioned to append after it.
        fn load(self: *Self, io: Io) OpenError!void {
            const length = try self.file.length(io);
            self.writer.pos = length;
            if (length == 0) return;

            const buffer = try self.arena.allocator().alloc(u8, @intCast(length));
            const read = try self.file.readPositionalAll(io, buffer, 0);
            var bytes = buffer[0..read];

            if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') {
                const complete = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |index| index + 1 else 0;
                switch (self.options.on_truncated) {
                    .fail => return error.TruncatedRecord,
                    .drop => {
                        self.dropped_bytes = bytes.len - complete;
                        try self.file.setLength(io, complete);
                        self.writer.pos = complete;
                        bytes = bytes[0..complete];
                    },
                }
            }

            var start: usize = 0;
            var expected: ?u64 = null;
            while (start < bytes.len) {
                const newline = std.mem.indexOfScalarPos(u8, bytes, start, '\n').?;
                const record = try self.parseLine(bytes[start..newline]);
                start = newline + 1;
                if (expected) |want| {
                    if (record.seq != want) return error.DiscontinuousSeq;
                } else {
                    self.base_seq = record.seq - 1;
                }
                expected = record.seq + 1;
                try self.list.append(self.arena.allocator(), record);
            }
            self.seq = self.base_seq + self.list.items.len;
        }

        fn parseLine(self: *Self, line: []const u8) OpenError!Record {
            _ = self.scratch.reset(.retain_capacity);
            const root = std.json.parseFromSliceLeaky(
                std.json.Value,
                self.scratch.allocator(),
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
            return .{
                .seq = @intCast(seq.integer),
                .at = at.integer,
                .version = version,
                .event = try self.eventFrom(version, ev, line),
                .bytes = line,
            };
        }

        fn eventFrom(self: *Self, version: u32, ev: std.json.Value, line: []const u8) OpenError!Event {
            if (version == self.options.schema_version) {
                return std.json.parseFromValueLeaky(
                    Event,
                    self.arena.allocator(),
                    ev,
                    .{},
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptRecord,
                };
            }
            if (version > self.options.schema_version) return error.NewerSchema;
            if (self.options.migrate) |migrate| return migrate(version, try self.retainedEv(line));
            if (comptime unknown_arm != null) return self.unknownEvent(line);
            return error.OlderSchema;
        }

        /// The record's `ev` member parsed into the journal's arena, so what
        /// a `migrate` hook or the `unknown` arm keeps outlives the read.
        fn retainedEv(self: *Self, line: []const u8) OpenError!std.json.Value {
            const root = std.json.parseFromSliceLeaky(
                std.json.Value,
                self.arena.allocator(),
                line,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptRecord,
            };
            if (root != .object) return error.CorruptRecord;
            return root.object.get("ev") orelse error.CorruptRecord;
        }

        fn unknownEvent(self: *Self, line: []const u8) OpenError!Event {
            switch (comptime unknown_arm.?) {
                .empty => return @unionInit(Event, "unknown", {}),
                .json_value => return @unionInit(Event, "unknown", try self.retainedEv(line)),
            }
        }

        fn readSnapshot(self: *Self, io: Io) OpenWithSnapshotError!?Snapshot {
            const path = try self.suffixedPath(snapshot_suffix);
            defer self.gpa.free(path);

            const arena = self.arena.allocator();
            const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
                error.FileNotFound => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return error.CorruptSnapshot,
            };
            const Document = struct { seq: u64, state: []const u8 };
            const document = std.json.parseFromSliceLeaky(Document, arena, bytes, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptSnapshot,
            };
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(document.state) catch return error.CorruptSnapshot;
            const state = try arena.alloc(u8, size);
            decoder.decode(state, document.state) catch return error.CorruptSnapshot;
            return .{ .seq = document.seq, .state = state };
        }
    };
}

/// Create `path`, write `bytes`, flush, `fsync`, close. On any failure the
/// file is left behind for the caller to remove.
fn writeFileDurably(io: Io, path: []const u8, bytes: []const u8) (Io.File.OpenError || Io.Writer.Error || Io.File.SyncError)!void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(io);
}

fn deletePath(io: Io, path: []const u8) Io.Dir.DeleteFileError!void {
    return Io.Dir.cwd().deleteFile(io, path);
}

test {
    _ = @import("journal_test.zig");
}
