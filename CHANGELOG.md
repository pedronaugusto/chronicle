# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- Events are strand's JSON types. strand has one API now, and chronicle writes and
  reads each record with `strand.json`: an event's own meaning is a
  `strandSerialize` and `strandDeserialize` pair where it was `jsonStringify` and
  `jsonParse`, which strand no longer reads; an event of any shape, and an
  `unknown` arm, is a `strand.json.Value` where it was a `std.json.Value`; a
  `migrate` hook reads the old shape with `strand.json.parseLeaky(Old, arena,
  event.bytes, .{})` where it called `event.parse`; and `copySince` copies events
  with strand's checked `core.cloneLeaky`. Text in an event must be UTF-8: an event
  holding bytes that are not is refused with `error.NotRoundTrippable`, where they
  were written as an array of numbers. A codec that refuses to write an event is
  `error.NotRoundTrippable` too. The lines are the bytes they were: a journal
  written before reads back and is written again byte for byte.

- chronicle requires Zig 0.17.0, and builds against strand c37ca7a, strand's Zig 0.17 line, and [airlock](https://github.com/pedronaugusto/airlock) 652b0e4, which makes every sync, atomic replace and backup batch.
- `close` is `finish`, and `CloseError` is `FinishError`. `finish` flushes the active segment, trims what was reserved past its records, syncs it and seals its index as `close` did, and leaves the journal open whether it succeeds or not: `deinit` is still owed, so `finish` sits beside `defer journal.deinit(io)`, and an append after it carries on. `close` released the journal even when it failed.
- `subscribeFrom` and `subscribeAllFrom` refuse a cursor below `oldestSeq() - 1` with `error.HistoryDropped` and register nothing, so a fold restored from a snapshot older than a `compact` or `dropSegmentsBefore` is told it would skip records. A cursor of zero still means everything the log holds.
- tailer names are lowercase letters, digits, `-` and `_`. On a filesystem that folds case, as macOS and Windows do by default, two names differing only in case shared one cursor file.
- `readers` takes the allocator its list is owned through, as `copySince` does. `Snapshot.deinit()` frees a snapshot's state, through the allocator `openWithSnapshot` was given, which the snapshot keeps.
- `appendAll` takes a `Commit`. `.group` is what it did: one sync, and a crash may leave a prefix. `.atomic` writes the batch's first and last sequence numbers (`"bf"`, `"bl"`) into each of its records and keeps it in one segment; an open drops a batch the log ends inside whole, as it drops a torn line, a reader beside the writer reads a batch once it is whole, and a walk refuses a batch that does not run from its first record to its last with `error.BrokenBatch`.
- `Flush` is airlock's `Reached`, what a sync reached, and `flush` is `.full` on every platform (`Reached.expected(.full)`), replacing `.full_fsync`, `.fsync` and `.flush_buffers`. `Status.flushed` is what the records' last sync reached: `.data` for a write into reserved space on Linux and Windows, and `.written` on a macOS filesystem that declines `F_FULLFSYNC`.
- Errors carry airlock's names: `BackupError` gains airlock's batch errors, `PublishedNotDurable` among them; `SnapshotError` and a tailer's `commit` take airlock's `WriteFileError` (`PublishedNotDurable`, `Busy`) in place of the rename and delete errors; `CompactError` gains airlock's create and commit errors; `OpenError` gains `airlock.PruneError`.
- `copySince` and `readers` return opaque `*Batch` and `*Readers` owners; replace direct fields with `records()`, `complete()` and `items()`, keep their pointers instead of values, and release each owner exactly once before its allocator.
- Journal, Replay and Tailer are opaque managed owners returned by pointer, including `Opened.journal`; keep their pointers, use methods to observe state (`Tailer.name()` borrows its name), and release each owner exactly once before its allocator, with replays and tailers released before their journal.
- `copySince` copies events without calling their codecs again, preserving Raw bytes and dynamic values; events must be finite trees of plain data and `CopyError` no longer includes `NotRoundTrippable`.
- pin strand at `3e5c57e40aedfc9b84171a4e9d2f4ee0e04feeb0`; `Raw.encode` adds `WriteFailed`, byte vectors accept strings and arrays, and framing bounds count payload bytes.
- `Tailer.cursor(io)` observes the committed cursor under the journal lock, replacing the mutable `Tailer.cursor` field.
- `openedWith(io)` returns the `Options` the journal was opened with, under the journal lock, replacing the public `options` field.
- `status(io)` returns a locked `Status` observation in place of the mutable `persistence_failed` and `dropped_bytes` fields.
- `oldestSeq(io)` and `segmentCount(io)` take the journal lock and return a cancelable observation of its inventory.
- `waitPast` returns the newest sequence number; `copySince(gpa, io, cursor)` replaces `records`, `since` and `Window` with an owned `Batch`, including every event reference, released with `deinit`.
- the `migrate` hook takes an allocator and the record's
  event as its bytes:
  `fn (arena: Allocator, from_version: u32, event: chronicle.Raw)`. `event`
  is checked as JSON and is a slice of the record's line, and
  `strand.json.parseLeaky(Old, arena, event.bytes, .{})` reads the old shape as a type, its strings
  borrowed from the line where they need no unescaping; the hook used to be
  handed a `std.json.Value` tree built for it. `arena` is the arena that owns
  the record being built, so what the hook parses and allocates lives as
  long as the record. `examples/migrate.zig` reads version 1 records at
  version 2. An `Event` arm named `unknown` may be a `chronicle.Raw` as well
  as `void` or a `strand.json.Value`, and then holds the older record's event
  as its bytes.
- Sequence numbers, byte counts and record counts are [aegis](https://github.com/pedronaugusto/aegis) types, kept apart so one cannot stand where another is wanted. `chronicle.Seq` is a position in the sequence (equality and an order, no arithmetic; `Seq.fromRaw(n)` and `raw()` cross to a plain integer, and `chronicle.beginning` is the place before the first record), `chronicle.Bytes` a length or offset, `chronicle.Records` a count. Every `u64` sequence number in the API is a `Seq`: the returns of `append`, `appendDeferred`, `appendAll`, `appendIf`, `appendAllIf`, `reconcile`, `lastSeq`, `oldestSeq`, `waitPast`, `backup` and `seqAtOrAfter`; the arguments `cursor`, `seq`, `keep_after_seq` and `Tailer.commit`; `Record.seq`, `Snapshot.seq`, `Expected.last` and `.found`, `Position.cursor` and its `Last`, `Reader.cursor`, `minCursor`, `Stats.oldest_seq` and `newest_seq`, and `segmentName` and `indexName`. `Options.max_segment_bytes`, `max_record_bytes`, `max_snapshot_bytes`, `preallocate_bytes`, `index_interval_bytes`, `tail_bytes`, `write_buffer_size` and `read_buffer_size` are `Bytes`; `max_segment_records` and `tail_records` are `Records`; `Status.dropped_bytes`, `Stats.bytes` and `Position.Last.start` and `.end` are `Bytes`; `Stats.records` and `verify`'s result are `Records`. chronicle adds aegis as a dependency.
- `SequenceExhausted` can also come from `compact` and the log's own numbering, not only from `append`: a record is never numbered past `maxInt(i64)` by any caller.

### Changed

- The journal's lock, and the state it guards, are aegis's `BlockingGuarded` over one struct, and `waitPast` waits on aegis's `Condition`; the package's own futex word, waiter count and wake count are gone. Nothing in the API changes. A helper that needs the lock now takes the guarded state, so it cannot be called without it. `waitPast`, `append` and `nudge` measure level with what they were (macOS and Linux, paired runs of the package's own benchmarks), and a reader canceled in the instant an append signals is still canceled.
- A segment file's name is a sequence number from 1 to `maxInt(i64)`; a file named for a larger number, which no record can carry, is no longer read as a segment.
- CRC32C is supplied by [warp](https://github.com/pedronaugusto/warp), pinned at `e607c19`, with runtime CPU dispatch and hardware kernels in baseline builds. Record and index checksum values are unchanged.

### Added

- `appendIf` and `appendAllIf` append only while the newest record is still the one the caller expected, as an event store's expected revision; otherwise they return `error.WrongExpectedSeq` with the newest sequence number in `Expected.found`, and write nothing.
- `indexName`, the name of the index file beside a segment, next to `segmentName`, for a caller that removes or inspects it.
- `Replay.rearmAt(io, position)` starts another pass on the same walk. A
  follower keeps one scan buffer, segment storage, line buffer and two record
  arenas across wakes; after the first pass, following one new record in the
  same segment allocates nothing. The position is checked again on every pass,
  with the same `error.StalePosition` contract as `Journal.replayAt`.
- `Journal.replayAt(io, position)` and `Replay.position()`: a walk that
  starts where an earlier one stopped. A reader that follows a log keeps the
  `chronicle.Position` its last pass ended at — the last record it read,
  its segment, its offsets and its checksum — and the next pass opens that
  file at that offset instead of seeking by its cursor and reading forward
  to it. The record the position names is read back first; a position into
  bytes a `compact`, `truncateAfter` or `dropSegmentsBefore` has changed is
  `error.StalePosition`, never records from the wrong place, and
  `replay(position.cursor)` is the way on. A walk that stops in front of a
  record the writer has not finished hands back a position in front of it.
  A follower waking for one new record in a million-record log: 17.7 µs a
  wake with `replay(cursor)`, 13.2 µs with `replayAt` (best of seven,
  interleaved).
- `appendDeferred(io, at, event)`: a record written, handed to the operating
  system and published at once, and made durable with the next flush of the
  file — an `append` or `appendAll` under `Sync.always`, a rotation, a
  snapshot, a close. Group commit asked for record by record: a process
  crash loses none of them, and a power cut at most the deferred records
  since the last flush, a suffix and never a gap.
- Name the existing replay position and reader replay types as `Journal.Replay.Position` and `Journal.Tailer.Replay` when separating their facades.
- `zig build bench` builds chronicle's own benchmarks in `bench/` (`chronicle-bench`, `work-bench` and `cover-bench`) into `zig-out/bench`, in chronicle's own tree only; CI compiles them.

### Changed

- Test lost write answers and cancel-protected writes with shakedown 1bb13e7 faults, replacing the local Io layers; pin preflight 87ff327 for the package contracts.
- A snapshot, a cursor and a compacted segment are written under a temporary name drawn at random (`.chronicle-tmp-` and 26 characters) and renamed into place, so two readers committing the same cursor never write into one temporary. A writer's `open` removes those temporaries once they are an hour old; a `<name>.tmp` left by an earlier version is not touched.
- Windows flushes the directory after a name changes, so a new segment, a compaction, a snapshot and a cursor survive a power cut under their names there too.
- A backup makes its copies durable together: on macOS and Windows a writeout of each file and one flush of the device, where it flushed the device once per file.
- A compaction's rename is retried on Windows while a scanner or indexer holds the segment.
- The fetched package holds the build files, `src` and the three documents; the examples, benchmarks, `ci/` and `.github/` stay in the repository.
- Builds against strand a8c5e83, whose reads reach chronicle's events. An event type that reaches itself is held to 512 levels of arrays and objects, and a record nested deeper reads as `error.CorruptRecord`, where it overflowed the stack. A `Raw` in an event where no value starts is `error.CorruptRecord`, where it panicked. A union event that declares `jsonl_tag` is written and read tagged inside its object (`{"type":"...",...}`).
- `backup` has the filesystem clone a sealed segment where it can (APFS); only indexes and the snapshot were cloned.
- `checksum` runs three CRC32C instruction chains side by side over a buffer of 768 bytes or more and joins them with a shift table, as zlib-ng and the crc32c crates do; the value is unchanged.
- Sync the journal's directory with `strand.syncDir` rather than a file handle borrowed from it: the same calls as before — `F_FULLFSYNC` on macOS, `fsync` on Linux, nothing on Windows.
- Write a record open and its checksum as a member through strand, and read the envelope's and the segment header's leading integers with strand, rather than trimming a brace and scanning digits here. The bytes on disk are unchanged; a journal written before is read and its records written again byte for byte. A leading integer with a zero in front of its digits, which is not JSON, is no longer read off the bytes and is refused as the parser refuses it.
- A batch with no tail or sink reserves no record storage and holds only one parsed record at a time when round-trip checks are enabled.
- Measured on a million 200-byte events, best of seven runs interleaved
  with the previous release's code: an append without `fsync` from 603,000
  to 745,000 records a second, a replay of all of them from 2.60 to 7.32
  million a second, a replay of the last hundred thousand from 38.4 to
  13.8 ms.
- A record's line is written and read by strand, which is now this
  package's one dependency, pinned by commit. strand writes the bytes
  `std.json` writes and reads what `std.json` reads, and the lines are the
  ones this package wrote before: a journal written by the previous code
  (in `src/testdata`) reads back as the events appended to it, takes new
  records on its chain, and the same events appended today are the same
  lines. Null optionals are still written, as `std.json`'s default has
  it. What that changes:
  - An event kept as a `strand.Raw` — a journal of events carried as their
    bytes — is read back as a slice of its line by strand's own decoder,
    where it went through `std.json`'s scanner a byte at a time.
  - A record holding a whole number written with a fraction or an exponent,
    which `std.json` (Zig 0.16.0) panics on casting, is read as the number
    it is when it fits the event's type and is `error.CorruptRecord` when it
    does not, on every path. `1.8e38` into a `u128` is the number.
  - A line not in the shape this package writes, a record written by hand,
    has its envelope read as its members' bytes rather than as a
    `std.json.Value`, and its event parsed from where it lies in the line
    like any other.
  - Written and read faster than the codec this package carried until now
    (`stringify.zig`, `parse.zig`, gone), whose fast paths and guard went
    to strand.
- An `append` or `appendAll` on a journal that keeps no record — no tail,
  no sink, no round-trip check — allocates nothing once the journal's line
  buffer has grown to the record's size. The line was a fresh allocation
  per record, freed as soon as the log had copied it.
- An append nobody is waiting on no longer makes a system call to wake
  one. `waitPast` counts itself in under the journal's lock before it
  sleeps, and a record or a nudge asks the operating system to wake
  readers only when one has; every `append` used to pay for a futex wake
  whether anyone waited or not.
- A sync is strand's (`strand.syncFile`): the same calls — `F_FULLFSYNC` on
  Darwin, `fsync` or `fdatasync` on Linux as the write needs, the system's
  flush on Windows — with two differences where the copy here had drifted.
  An interrupted `F_FULLFSYNC` or `fdatasync` is made again; it used to be
  answered with a plain `fsync`, a weaker call, and so was any failure the
  code did not name. Now a failure is reported, and only a filesystem that
  declines the stronger call gets `fsync`. Which directory a backup is
  going to is asked of strand's `FileId`, which is this package's directory
  identity moved there.
- A segment's lines are framed by strand's `LineReader` and `Tail`, where
  the segment store had readers of its own: a replay's walk, the scan an
  open makes of the newest segment, the read of a segment's first line and
  the search for its last. The store keeps only what is a segment's own —
  its first line, the space reserved after its records, the bound on a
  record — and every line keeps every byte before its newline, a `\r`
  included, since the checksum covers them all. A line whole in the read
  buffer is handed to the replay where it lies instead of being copied out
  of it, and the last line of a segment is found reading back a block at a
  time instead of reading a window twice as large again at each step.
- `backup` knows its own directory by what the filesystem calls it — device
  and inode on POSIX, volume serial and file id on Windows — and no longer by
  its resolved path. A destination that reaches the journal's directory
  through a symbolic link or a bind mount is refused with `BackupInPlace`;
  the check allocates nothing, and `BackupError` carries `Io.File.StatError`
  where it carried the errors of resolving a path. A destination that is
  itself a symbolic link to a directory is now that directory, where it was
  refused with `NotDir`.

### Fixed

- A journal's directory created by a writer's open was not made durable: an append
  that returned under `Sync.always` could be lost with the directory a power cut
  forgot. The directory and every parent the open creates are made durable through
  airlock's `makePath`, as a backup's destination is; `open` can fail with airlock's
  `MakePathError`.
- A compaction, a truncation, a retention drop or an open finishing an interrupted
  compaction removed several segments and synced the directory once: removals the
  disk may keep in any order could leave a hole, and the next open failed with
  `DiscontinuousSeq`. Each removal is made durable before the next.
- An index whose header counts more records than the sequence can number (a flipped bit in a word the entries' checksum does not cover) overflowed `base + count - 1` while the journal opened, trapping in Debug and ReleaseSafe and wrapping in ReleaseFast to a segment that ended before it began. It is a stale cache now and is rebuilt.
- `zig build bench` stopped at the raw-event workloads of the default run with `StreamTooLong`: the input they read, 200 MB at a million records, was limited to 64 MiB. The benchmark reads the whole file it is given.
- An index whose last entry names an offset past the end of its segment, with the checksum over the entries made to agree, resumed the active segment's index and stopped a later append on an assertion in Debug and ReleaseSafe. It is a stale cache now and is rebuilt.
- `preallocate_bytes` as large as a number can be (`maxInt(u64)`, meaning "reserve to the limit") overflowed the sum of the segment, the record and the reservation on the first append. The reservation is cut to `max_segment_bytes`, as it always was for any other size.
- A file in the journal's directory named like a segment for a number past `maxInt(i64)` (`18446744073709551615.log`) failed the open with `error.DiscontinuousSeq`; it is ignored, as every other name that is not a segment's is.
- A backup on a filesystem that clones (APFS) synced none of the segments it cloned; they are now made durable with the copies.
- A project that depends on chronicle builds: `build.zig` reaches the lazy `preflight` dependency through `b.lazyImport`, and only in chronicle's own tree.
- A batch refused part-way (`RecordTooLarge`, `NotRoundTrippable`) is taken back to where it started, without a rescan. Records longer than the write buffer had already reached the file; the journal latched as failed, and a reopen or `reconcile` returned them as committed.
- `append` parses its round trip with the options every read uses. An event that writes a member it does not read back is refused with `NotRoundTrippable`; it was written, and verify, replay and every open then refused the journal.
- `reconcile` and `refresh` hand the records they find after the newest one the journal knew to every subscribed sink, and wake every `waitPast`. A fold missed the record that survived a failed write, and a `.read` journal's waiters slept through a `refresh` until a `nudge`.
- `truncateAfter` removes a snapshot taken after the cut before cutting. Appends that passed the snapshot's number again made `openWithSnapshot` restore state folded from history that no longer exists.
- Under `on_truncated = .drop`, `open` drops a final record that kept its newline but not all of its bytes (a zero byte, or a checksum that does not match), as a power cut can leave it, and counts it in `dropped_bytes`. It refused the journal with `ChecksumMismatch`. Damage before the final record is still refused.
- A `.read` open of a journal whose writer has created the first segment and not yet written its header finds it empty; it was `UnsupportedFormat`.
- Handle cleanup failures explicitly and propagate record-header flush failures.
- `readers` and `minCursor` leave out a reader whose cursor file is deleted between the directory listing and its read, as a `forget` from another process can do; it was listed at cursor 0, which held every record back from retention.
- An open that refuses the log closes the index file it was reading; each such refusal used to keep one descriptor open.
- An empty segment with segments after it is refused as `UnsupportedFormat` and left in place. Only the newest can be a rotation that crashed before its header; open removed one in the middle as if it were, and then refused the log anyway.
- A record's checksum is read only as a JSON integer: one written with a `0` in front of its digits made a line that is not JSON, and it was accepted as a record and handed out as its bytes.
- A file in the journal's directory is a segment or an index only under the twenty digits its name is written with. A name with a sign or a `_` among them, which `parseInt` reads as the same number, was taken for a second copy of that segment, and an open deleted the real one.
- A zero read-buffer size uses the one byte needed for lookahead, so opening, replaying and backing up a journal make progress instead of aborting.
- The record byte limit counts the exact encoded line and checksum, so a record at the ceiling is accepted and one above it is refused before any file write.
- Encoding keeps its allocation-failure cause with its writer, so a custom stringify refusal returns `WriteFailed` rather than `OutOfMemory` without latching persistence failure.
- A rotation reserves segment inventory before changing files, so allocation failure cannot publish an active file with no matching segment owner.
- Segment-header, timestamp and back-link probes propagate allocation failure instead of treating valid bytes as missing or corrupt metadata.
- A torn-header recovery closes the files of its first attempt before restarting, so a failed replacement releases each file only once.
- The shared document reader preserves read-bound failures, so an oversized stored snapshot returns `SnapshotTooLarge` while an oversized cursor remains `CorruptCursor`.
- A replay keeps its record arena at a stable address, so a returned or moved walk preserves allocator contexts retained by its last event.
- Opening, snapshot restoration and final release observe and change journal state under its lock, including cleanup after an error.
- A positioned replay initializes under the journal lock, and independent readers own the decoding configuration and allocator they need without observing journal fields between calls.
- Tail records and staged writes keep their arenas at stable addresses, so allocator contexts retained by events survive publication, growth and eviction.
- An owned batch keeps its arena at a stable address, so allocator contexts retained by managed JSON containers survive returning and moving the batch.
- A read-only tail rebuild reads only the complete boundaries its inventory measured, so an external append cannot make a healthy journal look discontinuous.
- Replacing a backup owns its old-file inventory in one temporary arena, so a failed insertion cannot leak a copied filename.
- `replay`, `verify` and `Tailer.replay` choose their scans under the journal lock, so writers and other readers cannot race the segment inventory or shared index state.
- Opening or refreshing a journal works when the tail byte limit keeps no record; sequence continuity is checked by the walk, independent of cache eviction.
- A rebuilt tail is published only after the whole pass succeeds; a failed refresh leaves no partial batch claiming to be complete.
- A tail entry owns its record and arena together, so a refresh that runs out of memory cannot leave an unowned record behind.
- One reader for a record's envelope and a segment's first line, where the
  journal and the segment store each had their own: the shape this package
  writes read off the bytes, any other shape read by strand as its members'
  bytes, an integer only where it is written as one. The segment store's
  reader of a record's back-link found the first `,"p":` anywhere in the
  line; a record written by hand with its event before its envelope, and a
  member named `p` in its event, read the event's. It reads the envelope's.
- A cancel that lands on a write is no longer a failed write. `append`,
  `appendAll`, `snapshot`, `compact`, `truncateAfter`, `dropSegmentsBefore`,
  `reconcile`, `refresh`, `close` and `deinit` block the task's cancelation
  once they hold the lock, so a record a cancel reached mid-write is written
  and published whole, and the journal is not latched as though the disk had
  refused it; the cancel is reported by the task's next cancelation point. A
  cancel while one of them waits for the lock still returns `error.Canceled`
  with nothing written.
- A reader canceled as a record or a nudge arrives is canceled. `waitPast`
  waited on an `Io.Condition`, and Zig 0.16.0's condition lets a broadcast
  swallow a cancel that lands in the same instant: the wait takes the
  broadcast, returns without `error.Canceled`, and the cancel is gone, so
  the reader's next wait never returned and whatever canceled it waited on
  it. `waitPast` now waits on a futex word the appends and nudges bump, and
  returns `error.Canceled` whichever wins.
- A cancel that lands on an index read is a cancel. The lookups an index
  only speeds up — where a walk starts, `seqAtOrAfter`, a clean open's
  inspection, resuming an index — took any failed read as "no index" and
  went on without it, a cancel included: the cancel was spent, the walk
  carried on, and the task's next wait could not be canceled. They return
  `error.Canceled` now (a clean open's inspection tasks put it back for
  their caller), and a canceled rebuild no longer marks a segment as
  having no index.

## [0.6.0] - 2026-09-20

A clean reopen proved rather than scanned, an append that costs one
allocation, and the crash and backup cases a second reading found.

### Changed

- Under `sync = .never`, sealing a segment's index and starting a new segment no longer flush to the drive: the index is held to the log's own level, and an index a power cut left ahead of its segment is checked against the segment and rebuilt on the next open, as before.
- `append` writes a record's envelope by hand into the one buffer that becomes the stored bytes, sized from the record before it, so a record costs one allocation instead of three and no copy; the bytes are unchanged.
- Clean reopening a million-record journal is 5.6 times faster, measured from 5.768 ms to 1.035 ms, by proving clean indexes without scanning the newest segment.
- The memory contract now names the fixed metadata held per segment.

### Fixed

- Backup stops when it cannot prove the destination differs from the source.
- Dropping segments evicts the same records from the in-memory tail.
- A snapshot newer than a truncated log is ignored instead of restoring rolled-back state.
- Replay anchors each segment to the base sequence and chain root in its header.
- Indexed replay checks the cursor record before accepting its successor.
- Directory writeback failures are returned instead of treated as success.
- `close` reports final flush and sync failures; `deinit` remains a best-effort fallback.
- A read-only backup refreshes rotations and omits a snapshot it cannot freeze with the log.
- Snapshot publication durably follows every record it describes under every sync policy.
- Reusing a backup destination removes segment, index and snapshot files absent from the source.
- Read-only replay stops at a live writer's zero-filled reservation even when it exceeds the record limit.
- Segment headers are recognized when they span multiple read-buffer chunks.
- An index interval wider than its on-disk field returns `error.IndexIntervalTooLarge`.
- Writing a snapshot enforces the same size limit used to read it.
- `reconcile` reports what survived an indeterminate append failure and clears the write latch.
- Falling back from a sealed index closes the abandoned file handle.
- Empty compacted logs report both sequence bounds as zero in `stats`.
- Interrupted compaction and segment creation recover after a writer is killed at an operation boundary.
- A compaction killed after its rename no longer leaves the segments before the cut standing as a hole in front of the rewrite; the next open removes them with the segment it replaced.

## [0.5.0] - 2026-09-19

A log whose records say what they are and what came before them, a durable
write that is durable on the platform it runs on, and an index that proves
itself. **A 0.4.0 journal does not open**: the framing carries its version
now, and a file without one is refused by name rather than read as though it
were this one. Replay an old journal into a new directory.

### Breaking

- **A segment file starts with a line saying what it is.**
  `{"chronicle":1,"base":<u64>,"root":<u32>}` — the framing version, the
  sequence number the file starts at, and the number its first record links
  back to. A `.log` whose first line is not one is `error.UnsupportedFormat`.
  A zero-byte one is a segment whose creation did not finish, and the next
  open writes the line again.
- **Every record carries the checksum of the record before it.** A line is
  `{"seq","at","v","p","ev","c"}` where `p` is the previous record's `c`, and
  the first record in a file carries the file's root. A record spliced in from
  somewhere else, or left over from an earlier life of a file, is
  `error.BrokenChain` rather than a fold that is quietly wrong. The chain runs
  across a rotation and across a compaction, because the records do; a file
  whose predecessors have been dropped gets a random root, so nothing links
  onto it by accident. `chronicle.checksum` is unchanged and still covers one
  line on its own, because the link is inside the line.
- **The index is version 3.** A ninety-six byte header with thirty-six spare
  bytes in it, naming the segment and its record count as well as its length,
  saying whether the timestamps rise, and carrying a checksum of the entries —
  so an index proves itself against the header rather than by reading the
  segment's last record back. Entries are twenty-four bytes and name their
  record, which is what lets there be fewer of them than there are records.
  An index in an older format reads as stale and is rebuilt, as it always has.
- **`Options.index_interval_bytes`, 4096 by default.** One entry per 4096
  bytes of segment instead of one per record: a fortieth of the size, with a
  walk of at most one interval after the seek. Zero is one entry per record,
  which is what 0.4.0 wrote.
- **The snapshot and a reader's cursor carry `fmt`.** `{"fmt":1,"seq":…}`. A
  version this package does not know is `error.UnsupportedFormat` rather than
  a starting point that is quietly wrong.
- **`Options.max_record_bytes`, one mebibyte by default.** `append` refuses a
  longer line and a read refuses a segment with no newline within that many
  bytes, so a damaged segment is not taken into memory whole to find out it
  holds no record. `AppendError` gains `RecordTooLarge`.
- **`Options.verify_round_trip`, false by default.** `append` used to parse
  every record back out of the bytes it had just written, a third of what an
  append costs, even where nothing would read the record. It still does so
  wherever something will — a tail, a sink — because that is what makes an
  `Event` whose slices point at a stack buffer safe to append; where nothing
  will, this is how to ask for the check and the `NotRoundTrippable` answer
  anyway.
- **`chronicle.segmentName` returns a zero-terminated array**, because a copy
  now goes to the operating system by name.
- **`Stats.bytes` counts records**, not the line at the head of each segment.

### Added

- **`subscribeAll(io, sinks)` and `subscribeAllFrom(io, sinks, cursor)`.**
  Five folds subscribed one at a time read the log five times. One pass fed to
  all of them costs what one fold costs — the extra callbacks per record are
  free beside the decode — and it is one call under one lock, so a record
  appended beside it lands in all of them or in none. Measured 1238 ms against
  248 ms for five folds over a million records, where one fold is 246 ms.
- **`unsubscribe(io, sink)`.** A fold could only ever be added. A reconnecting
  client's fold is dropped when the client goes.
- **`readers(io)` and `minCursor(io)`.** Every named reader that has committed
  a cursor beside the log, and the lowest number any of them is past — which
  is what retention needs and had no way to find out.
- **The checksum goes through the instruction for it.** aarch64 and x86-64
  have both had one for this polynomial since 2011, behind the target's
  features, with the table where the machine has none. The same number:
  127 ns per record before, 3.0 ns after, and 0.43 GB/s against 9.6 GB/s over
  a large buffer. A replay of a million records measured 0.888 s before and
  0.248 s after, which is this and the parse together.
- **`Options.preallocate_bytes`, zero by default.** The active segment is kept
  zero-filled that far ahead of its records, so an append writes into space the
  file already has rather than extending it — which is what makes the cheaper
  flush sufficient on the platforms that have one. A rotation and a close cut
  the reservation back. A run of zeros at the end of a segment is therefore
  space a writer reserved and never filled, not a record it did not finish: a
  record can hold no zero byte, so the repair pass counts the bytes up to the
  last one that is not zero and leaves the rest to the next append.
- **`Options.max_snapshot_bytes`, sixty-four mebibytes by default.** What is
  in a snapshot is the caller's fold, so how large one may be is the caller's
  number. A larger one is `error.SnapshotTooLarge` instead of an unbounded
  read.
- **A backup asks the filesystem to copy the bytes.** A sealed segment is
  bytes that will never change again: Darwin shares their extents, Linux hands
  the copy to the filesystem. Every call may say no — a filesystem that will
  not share, a kernel without it, two directories on different mounts — and
  the answer is then the byte copy, so the copy that lands is the same either
  way.
- **A batch does not have to fit in memory first.** `appendAll` serialises each
  record as it stages it and keeps only the ones something will read, so a
  journal with no tail and no sink holds one line at a time however long the
  batch. A record the journal cannot form takes back the lines already staged,
  so a refused batch leaves the log exactly as it was.
- **A lookup by time bisects where it can.** The index says whether the
  timestamps in a segment rise; where they do, `seqAtOrAfter` halves the
  entries instead of reading them. Measured 444 µs before and 34 µs after.
  Where they do not, it is the search it always was.
- **Two more fuzz targets, and one that fuzzes the calls.** One over an
  arbitrary `.cursor` file, the one file whose contents come from outside the
  log; one over an arbitrary first line of a segment; and one that drives a
  random run of `append`, `appendAll`, `compact`, `truncateAfter`,
  `dropSegmentsBefore`, `backup` and `snapshot`, cuts the newest segment at a
  random byte, and asserts the invariant every promise rests on — a continuous
  prefix, every checksum good, every record linked to the one before it, no
  record that was never acknowledged, and a next append that takes the next
  number.
- **The numbers are tests.** A seek into the newest segment against one into a
  sealed segment, an open against the same open with the index deleted, five
  folds against one, and the rates an append and a replayed record run at.
  Nothing in the suite would have caught the seek regression above; these
  would.

### Fixed

- **A seek into the segment being written to scanned it.** The active
  segment's index file was created write-only, so the live-index fast path
  could never read a byte back and every seek into the newest segment fell
  through to a scan. Measured 27 070 µs before and 34 µs after, over a
  million records.
- **`.always` did not survive a power cut on macOS.** `fsync` there returns
  once the bytes are in the drive's write cache. A durable write now goes
  through `fcntl(F_FULLFSYNC)` on Darwin, which asks the drive to flush its
  media, and through `fdatasync` on Linux when the write went into space the
  file already had. The cost is real and was being hidden: an `append` at
  `.always` measured 28 µs before and four to six milliseconds after on this
  machine, which is what a media flush costs on a consumer drive. `appendAll`
  is how to pay it once for many records, and `chronicle.flush` names the call
  this platform makes.
- **A clean close left an index nothing took.** `deinit` sealed the active
  segment's index with the exact length it described and `open` then truncated
  it and scanned the segment again. Opening a million-record log measured
  69 ms before and under ten after.
- **`replay()` could write.** It is public and takes no lock, and it could
  reach the index rebuild — creating and filling a file, and flushing the
  active segment's index writer, while another task was inside `append`. A
  walk now reads an index that is there and otherwise starts at the segment's
  first record; `open`, `refresh`, `subscribe` and `seqAtOrAfter` hold the
  lock and are what build one.
- **A cursor of every one overflowed.** `replay(maxInt(u64))`, which a
  `.cursor` file can ask for, added one to it. Found by the new
  crash-consistency fuzz target on its first run.

## [0.4.0] - 2026-09-14

### Breaking

Only the index sidecar: no journal needs converting and no record changes.

- **The index format is version 2.** An index now carries a timestamp beside
  every byte offset, and its header carries the lowest and highest timestamp in
  the segment, which is what `seqAtOrAfter` needs to skip a whole segment
  exactly rather than by assuming the timestamps rise with the sequence
  numbers. The header grows from sixteen bytes to thirty-two and each entry
  from eight to sixteen. **Old journals open unchanged**: an index in the older
  format reads as stale, exactly as a missing or mismatched one does, and is
  rebuilt from its segment the first time something asks for it. An index has
  never been anything but a cache, and this is what that has always meant.
  Anything reading a `.idx` file with something other than this package has to
  be taught the new shape; README.md states it byte for byte.

### Added

- **`appendAll(io, entries)`.** Write a batch of records under one `fsync`
  instead of one each, and get back the sequence number of the last. It is
  group commit and not a transaction, and says so: a crash inside the batch
  leaves a prefix of it on the disk, with a torn final line at worst, which is
  the same shape a crash inside a single `append` leaves and is repaired the
  same way. Nothing is published until the bytes are durable, so a sink still
  never sees a record the disk does not have. `Entry` is the pair `append`
  takes as two arguments.

- **`Tailer`.** A named reader whose cursor lives in `<path>/<name>.cursor`,
  beside the log: `tailer(io, name)` reads back the number that name last
  committed, `Tailer.replay` walks from it, `Tailer.commit` moves it, and
  `Tailer.forget` removes the file. The cursor is written to a neighbouring
  file and renamed into place, so a crash leaves either the whole old number
  or the whole new one. It is the one file a journal opened with
  `Options.access = .read` writes: still nothing to the log, so a named reader
  is safe beside the writer and beside every other named reader.

- **`seqAtOrAfter(io, at)`.** The lowest sequence number whose record is
  stamped at or after a given moment, or null when none is. It is a search and
  not a bisection, because nothing makes a caller pass its timestamps in
  order: every segment whose highest timestamp reaches the moment is looked
  inside, oldest first, and one whose highest is below it is skipped without
  its file being opened. A sealed segment is answered from its index; the
  active one, whose index is not sealed yet, is walked, and only when its own
  timestamps say a record could be in there.

- **`backup(io, dest)`.** Copy the journal into another directory while it is
  running, and get back the newest sequence number the copy holds. Every
  sealed segment goes whole, the newest one goes up to its last complete
  record *at the moment of the call* — its length measured and its newlines
  walked there and then, not taken from what this process last read — the
  sealed indexes go with their segments, and the snapshot goes first so that
  it can never name a record the copy does not hold. So the copy is a prefix
  of the log and opens as a journal of its own. The lock is not copied, nor
  are the cursor files of named readers: those belong to the readers of the
  directory being copied. A destination that is the journal's own directory
  is `error.BackupInPlace` rather than a log copied over itself.

### Changed

- **`snapshot_temporary_name` is gone** from `src/journal/log.zig`, where it named the
  file a snapshot is written to before it is renamed into place. It was never
  re-exported from the package root.

### Fixed

- **A walk over a log another process is appending to could hand back half a
  record.** A scan that ran out of file part-way through a record asked the
  reader for the byte after what it had streamed, and took *a* byte for the
  newline that ends a record. A writer that appended in between made that byte
  the rest of the record, so the walk returned a truncated line as if it were
  whole and was one byte out for every record after it — `error.CorruptRecord`
  or `error.ChecksumMismatch` from a log that was never damaged. The byte is
  now compared against the newline rather than counted, so a record that was
  not finished when the walk reached it is the end of the walk, which is what
  `Options.access = .read` has always promised. Nothing on the disk was ever
  wrong, so nothing needs repairing.

## [0.3.0] - 2026-09-14

A record that can say whether it is still the record that was written, and a
durability setting that says what it is buying. 0.2.0 detected a torn tail and
nothing else: a byte that changed after the fact produced a line that parsed,
an event that type-checked and a fold that was quietly wrong.

### Breaking

- **`Options.fsync: bool` is now `Options.sync: Sync`**, one of `.always`,
  `.on_segment` or `.never`. `fsync = true` is `.always`, which is the default,
  and `fsync = false` is `.never`. The level in between is new: `fsync` when a
  segment is sealed and when the journal is closed, which survives a kill but
  not a power cut. README.md states the promise and the cost of each in a
  table, because a durability knob without one is a knob.
- **Records carry a checksum.** A line written by 0.3.0 ends `,"c":<u32>}`
  where `c` is the CRC32C of everything before it. The format is still one
  JSON object per line, still readable with whatever reads lines. **Old journals open
  unchanged**: a record with no `c` has nothing to check and is read exactly as
  it was, so a 0.2.0 directory needs no conversion and gains checksums as it is
  appended to. A 0.3.0 journal read by 0.2.0 is also fine, since the extra
  member is ignored on the way in.
- **`ReadError` has a new arm, `ChecksumMismatch`**, separate from
  `CorruptRecord` because the two say different things: one line is not a
  record, the other is a record that is not the one that was written.

### Added

- **A verified read path.** Every path that turns a line into a record checks
  the checksum before parsing the event — `open`, `replay`, `subscribe`.
  `chronicle.checksum` is the same function, public, so a segment can be
  checked by something that is not this package.
- **`Options.verify`.** `.quick`, the default, reads the newest segment and one
  line of each older one, as `open` always has. `.full` reads every record of
  every segment through every check, which costs the log instead of one
  segment. `verify(io)` runs the same pass on demand and reports how many
  records it read.
- **`truncateAfter(io, seq)`.** Drop every record after `seq`, so `lastSeq`
  becomes `seq` and the next `append` is `seq + 1`. Whole segments past the cut
  are unlinked newest first and the segment holding the cut is shortened to the
  record boundary, so every state the directory passes through is a log that
  opens — one that may still hold records the call was asked to drop, which is
  why calling it again is the answer to a crash inside it. It is the one call
  that moves the sequence backwards, and it says so.
- **`stats(io)`.** Segments, records, bytes, and the oldest and newest sequence
  numbers, read off what the journal already knows: no file is opened and
  nothing is scanned.

## [0.2.0] - 2026-09-13

The log a daemon runs on for a year, rather than one that must fit in memory.
0.1.0 read the whole file at `open` and kept every record there, took no lock,
and had one file with no way to shed the front of it; every limit below was a
reason not to use it in the place it was written for.

### Breaking

All of it in the same direction: what used to be a file is now a directory of
segments.

- **The package is called `chronicle`.** `@import("zjournal")` becomes
  `@import("chronicle")`, `src/zjournal.zig` becomes `src/chronicle.zig`, and
  the dependency name in `build.zig.zon` changes with them. Nothing else about
  the name means anything: the type is still `Journal(Event)`.
- **`path` names a directory.** `open(gpa, io, "ledger")` creates and owns
  `ledger/`, holding `lock`, the segments, their indexes and `snapshot`. A
  0.1.0 journal is a file where 0.2.0 expects a directory, so it is not read;
  replay it into a new one, or point the new path somewhere else.
- **`records()` and `since(cursor)` return a `Window`, not a slice.** A journal
  longer than memory cannot hand out its history, so what it hands out says so:
  `Window.records` is the tail, and `Window.complete` is false when the cursor
  reaches back further than the tail does. `waitPast` returns one too.
- **A record from the tail lasts until the tail releases it**, which the next
  `append` may do, rather than until the next `compact`. A record from a
  `Replay` lasts until the next `next`, and one handed to a `Sink` lasts for
  the call. The arena that used to make every slice live until `compact` is
  gone, because it was the thing that made memory grow with the log.
- **`Snapshot.state` belongs to the caller** and is freed with the allocator
  `openWithSnapshot` was given, for the same reason.
- **`compact` no longer keeps the newest record.** It does not have to: a
  segment is named for the record that will go into it, so a log compacted to
  nothing still knows where the sequence got to. `compact(io, lastSeq)` now
  leaves an empty log whose next `append` continues.
- **`snapshot_suffix` and `compact_suffix` are gone**, replaced by
  `lock_name`, `snapshot_name`, `segment_extension`, `index_extension` and
  `segmentName`.
- **`fail_compact_before_rename` is gone.** The crash it simulated is made on
  the disk now — the suite writes the two segments a compaction leaves when it
  dies between its rename and its unlink, and opens that — so the seam does not
  have to exist in the package to be tested.

### Added

- **Streaming reads.** `open` reads the newest segment and one line of each
  older one. `replay(io, cursor)` walks the log from the disk holding one
  record and one read buffer, and `subscribe` is built on it, so a fold over a
  history longer than memory costs the largest record and not the history.
- **Segments.** The log rotates at `Options.max_segment_bytes` or
  `Options.max_segment_records` into files named after the record they start
  with, zero-padded to twenty digits so the directory sorts in sequence order.
  The reader walks them in order; `segmentCount` says how many there are.
- **An index.** A sidecar of one byte offset per record, so `since` and
  `replay` on an old cursor are a seek rather than a scan. It is a cache and is
  checked as one, against the segment length it names and against the sequence
  number of the record at its last offset; anything that disagrees is rebuilt.
- **An advisory lock.** A writer holds one on `<path>/lock` for as long as it
  is open, so a second writer gets `error.Locked` instead of interleaving
  half-records. `Options.access = .read` takes no lock and writes nothing at
  all, which is what makes a reader safe beside a live writer; `refresh` is how
  it picks up segments the writer has added since.
- **Retention you ask for.** `dropSegmentsBefore(io, seq)` unlinks the whole
  segments a snapshot covers, one `unlink` each, without rewriting anything and
  without ever touching the segment being written to. Nothing drops history on
  your behalf.
- **A fourth durability promise.** The journal's directory is `fsync`ed after a
  file in it is created, renamed or removed, so a power cut cannot leave a file
  whose contents reached the disk but whose name did not. Windows has no
  equivalent and README.md says so.
- **Bounded memory, stated.** `Options.tail_records` and `Options.tail_bytes`
  size what is kept parsed; `Options.read_buffer_size` sizes what a read
  streams through. Nothing else grows with the log.
- **`ci/linux.sh` and `ci/linux.Dockerfile`.** The suite in Debug and
  ReleaseSafe on Linux, in a container, from a machine that is not one —
  because a lock, a rename and a directory `fsync` are exactly the things that
  differ between kernels.

## [0.1.0] - 2026-09-13

First release. `Journal(Event)` over any type `std.json` can write and read
back.

### Added

- One JSON object per line — `seq`, `at`, `v`, `ev` — read back into records
  that keep both the parsed event and the exact bytes it was stored as, so a
  consumer can forward the durable form without re-encoding and `compact` can
  copy a record it could not have re-serialised.
- The crash cases as named outcomes rather than as behaviour: a sequence that
  continues across restarts, an unterminated final line detected and repaired
  with the dropped byte count reported, `error.NewerSchema` and
  `error.OlderSchema` for drift in either direction, a `migrate` hook and an
  `unknown` arm for the older side, and a persistence failure latched for the
  life of the journal so no reader can see a record the disk does not have.
- Sinks that receive the records already on disk and then every record
  appended, so one fold is built the same way from either.
- Snapshots and compaction, both written to a neighbouring file and renamed
  into place; compaction always keeps the newest record, because a journal
  compacted to empty would start counting from one again.
- Every file operation and the wait primitive through `std.Io`, so the suite
  runs on `std.testing.io` and the package runs on a threaded one.
- Fuzz tests over arbitrary journal and snapshot file contents, because the
  file shapes this package exists to survive are the ones nobody chose.

[Unreleased]: https://github.com/pedronaugusto/chronicle/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.6.0
[0.5.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.1.0
