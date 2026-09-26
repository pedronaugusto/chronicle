# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- `appendDeferred(io, at, event)`: a record written, handed to the operating
  system and published at once, and made durable with the next flush of the
  file — an `append` or `appendAll` under `Sync.always`, a rotation, a
  snapshot, a close. Group commit asked for record by record: a process
  crash loses none of them, and a power cut at most the deferred records
  since the last flush, a suffix and never a gap.

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

## [0.6.0] - 2026-09-20

A clean reopen proved rather than scanned, an append that costs one
allocation, and the crash and backup cases a second reading found.

- Under `sync = .never`, sealing a segment's index and starting a new segment no longer flush to the drive: the index is held to the log's own level, and an index a power cut left ahead of its segment is checked against the segment and rebuilt on the next open, as before.
- `append` writes a record's envelope by hand into the one buffer that becomes the stored bytes, sized from the record before it, so a record costs one allocation instead of three and no copy; the bytes are unchanged.
- Clean reopening a million-record journal is 5.6 times faster, measured from 5.768 ms to 1.035 ms, by proving clean indexes without scanning the newest segment.
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
- The memory contract now names the fixed metadata held per segment.
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

- **`snapshot_temporary_name` is gone** from `src/log.zig`, where it named the
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

[0.5.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/chronicle/releases/tag/v0.1.0
