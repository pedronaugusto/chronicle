# Changelog

Each entry says what the old shape could not express, so a port has the reason
and not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

## Unreleased

New:

- **`appendAll(io, entries)`.** Write a batch of records under one `fsync`
  instead of one each, and get back the sequence number of the last. It is
  group commit and not a transaction, and says so: a crash inside the batch
  leaves a prefix of it on the disk, with a torn final line at worst, which is
  the same shape a crash inside a single `append` leaves and is repaired the
  same way. Nothing is published until the bytes are durable, so a sink still
  never sees a record the disk does not have. `Entry` is the pair `append`
  takes as two arguments.

## 0.3.0

A record that can say whether it is still the record that was written, and a
durability setting that says what it is buying. 0.2.0 detected a torn tail and
nothing else: a byte that changed after the fact produced a line that parsed,
an event that type-checked and a fold that was quietly wrong.

Breaking:

- **`Options.fsync: bool` is now `Options.sync: Sync`**, one of `.always`,
  `.on_segment` or `.never`. `fsync = true` is `.always`, which is the default,
  and `fsync = false` is `.never`. The level in between is new: `fsync` when a
  segment is sealed and when the journal is closed, which survives a kill but
  not a power cut. README.md states the promise and the cost of each in a
  table, because a durability knob without one is a knob.
- **Records carry a checksum.** A line written by 0.3.0 ends `,"c":<u32>}`
  where `c` is the CRC32C of everything before it. The format is still one
  JSON object per line and `tail -f` is still a debugger. **Old journals open
  unchanged**: a record with no `c` has nothing to check and is read exactly as
  it was, so a 0.2.0 directory needs no conversion and gains checksums as it is
  appended to. A 0.3.0 journal read by 0.2.0 is also fine, since the extra
  member is ignored on the way in.
- **`ReadError` has a new arm, `ChecksumMismatch`**, separate from
  `CorruptRecord` because the two say different things: one line is not a
  record, the other is a record that is not the one that was written.

New:

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

## 0.2.0

The log a daemon runs on for a year, rather than one that must fit in memory.
0.1.0 read the whole file at `open` and kept every record there, took no lock,
and had one file with no way to shed the front of it; every limit below was a
reason not to use it in the place it was written for.

Breaking, and all of it in the same direction — what used to be a file is now a
directory of segments:

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

New:

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

## 0.1.0

First release. `Journal(Event)` over any type `std.json` can write and read
back, with:

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
