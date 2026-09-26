# chronicle

[![CI](https://github.com/pedronaugusto/chronicle/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/chronicle/actions/workflows/ci.yml)

chronicle is an append-only event log. A journal is a directory of segment
files holding one JSON object per line, each with a sequence number, a
timestamp and a schema version, and a program folds those records into
whatever state it needs — from the disk at startup and live afterwards.

```
{"chronicle":1,"base":1,"root":3116291790}
{"seq":1,"at":1700000000000,"v":1,"p":3116291790,"ev":{"account_opened":{"id":1,"owner":"ada"}},"c":2544158864}
{"seq":2,"at":1700000000100,"v":1,"p":2544158864,"ev":{"deposited":{"id":1,"cents":5000}},"c":3032764768}
```

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs; `ci/readme_usage.sh` extracts it
and CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const chronicle = @import("chronicle");

var balances: Balances = .{};
var last: u64 = 0;
{
    // Open the log. The directory is created if it is not there, the
    // newest records are read back, and the sequence number continues
    // from the last one, so a restart never reuses a number. A second
    // writer would get error.Locked instead of this journal.
    var ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
    defer ledger.deinit(io);

    // A sink is a fold. Subscribing streams it every record already on
    // disk -- one at a time, however long the history -- and then every
    // record appended, so the state is built the same way whether it
    // came from a file or from a live writer.
    try ledger.subscribe(io, balances.sink());

    // Append. The returned sequence number means the bytes are on the
    // disk: the record is written, flushed and fsynced before any reader
    // can see it.
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    _ = try ledger.append(io, now, .{ .account_opened = .{ .id = 1, .owner = "ada" } });

    // A batch goes down under one fsync instead of one each. It is group
    // commit and not a transaction: a crash inside it leaves a prefix of
    // it on the disk, exactly as a crash inside one append leaves a torn
    // line, and the next open repairs it the same way.
    last = try ledger.appendAll(io, &.{
        .{ .at = now, .event = .{ .deposited = .{ .id = 1, .cents = 5_000 } } },
        .{ .at = now, .event = .{ .withdrawn = .{ .id = 1, .cents = 1_250 } } },
    });

    // Write the fold out beside the log and drop the records it covers,
    // so the next start replays three records instead of three million.
    // Nothing drops history on your behalf; this is the call that does.
    try ledger.snapshot(io, std.mem.asBytes(&balances));
    try ledger.compact(io, last);

    _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 700 } });
}

// Starting again: restore the snapshot, then fold only what came after
// it. Without a snapshot `from` stays 0 and the whole log is replayed.
const opened = try Ledger.openWithSnapshot(gpa, io, path, .{ .schema_version = 1 });
var reopened = opened.journal;
defer reopened.deinit(io);

var restored: Balances = .{};
var from: u64 = 0;
if (opened.snapshot) |snapshot| {
    defer gpa.free(snapshot.state);
    restored = std.mem.bytesToValue(Balances, snapshot.state[0..@sizeOf(Balances)]);
    from = snapshot.seq;
}
try reopened.subscribeFrom(io, restored.sink(), from);
```
<!-- END GENERATED -->

## Install

```
zig fetch --save git+https://github.com/pedronaugusto/chronicle
```

```zig
const chronicle_dep = b.dependency("chronicle", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("chronicle", chronicle_dep.module("chronicle"));
```

One module, no dependencies and no build options: the only knobs are the
`Options` passed to `open`.

## The API

`chronicle.Journal(comptime Event: type)` returns a type with:

| | |
|---|---|
| `open(gpa, io, path, options)` | Create or read back a journal directory. |
| `openWithSnapshot(gpa, io, path, options)` | The same, plus the snapshot beside it. |
| `close(io)` | Durably flush, close, unlock and release; returns a shutdown failure. |
| `deinit(io)` | Best-effort close for a scope that cannot return an error. |
| `append(io, at, event)` | Write one record durably; returns its sequence number. |
| `appendAll(io, entries)` | Write a batch under one `fsync`; returns the last sequence number. |
| `appendDeferred(io, at, event)` | Write and publish one record now, durable with the next flush. |
| `reconcile(io)` | After a persistence error, read back what survived and clear the latch. |
| `records()` | The tail, oldest first, as a `Window`. |
| `since(cursor)` | The tail after `cursor`, as a `Window`. |
| `waitPast(io, cursor)` | Block until there is one, then `since(cursor)`. |
| `replay(io, cursor)` | A walk over every record after `cursor`, from the disk. |
| `nudge(io)` | Wake the waiters with no record behind it. |
| `lastSeq(io)` | The newest sequence number, or zero. |
| `seqAtOrAfter(io, at)` | The lowest sequence number stamped at or after `at`. |
| `oldestSeq()` | The oldest one still held. |
| `segmentCount()` | How many files the log is spread over. |
| `refresh(io)` | Read the directory again — how a reader tails a writer. |
| `tailer(io, name)` | A named reader, with the cursor it last committed. |
| `subscribe(io, sink)` | Fold every record, from the disk and then live. |
| `subscribeFrom(io, sink, cursor)` | The same, starting after a snapshot. |
| `subscribeAll(io, sinks)` | Fold every record into several folds, over one pass. |
| `subscribeAllFrom(io, sinks, cursor)` | The same, starting after a snapshot. |
| `unsubscribe(io, sink)` | Drop a fold. |
| `readers(io)` | Every named reader and the cursor it committed. |
| `minCursor(io)` | The lowest of those, which is what retention may drop to. |
| `snapshot(io, state_bytes)` | Write the fold out beside the log. |
| `backup(io, dest)` | Copy the journal into another directory while it runs. |
| `compact(io, keep_after_seq)` | Rewrite the log, keeping the records after the cut. |
| `dropSegmentsBefore(io, seq)` | Unlink the whole segments a snapshot covers. |
| `truncateAfter(io, seq)` | Drop every record after `seq`, handing the numbers back. |
| `verify(io)` | Read every record of every segment through every check. |
| `stats(io)` | Segments, records, and the bytes they take. |

Plus `chronicle.checksum(covered)`, which is the checksum a record carries,
and `chronicle.segmentName(base_seq)`, which is the file a sequence number
lives in; `chronicle.flush`, which names the call a durable write makes here;
and, on the type `Journal(Event)` returns, `Record`, `Entry`, `Window`,
`Replay`, `Tailer`, `Sink`, `Reader`, `Readers`, `Options`, `Snapshot`,
`Opened`, `Migrate`, `Stats` and one named error set per operation, with
`Sync`, `Flush` and `Verify` at the module root. Every
public declaration carries a doc comment stating its contract;
`src/chronicle.zig` is the reference and `src/log.zig` the segment store under
it. `Event` may be any type `std.json` can write and read back; a tagged union
is the expected shape, because it gives each record a name on disk and an
exhaustive `switch` in the fold.

## Design

**What a journal directory holds.**

```
ledger/
  lock                          zero bytes; the writer's advisory lock
  00000000000000000001.log      records 1..800
  00000000000000000001.idx      where some of those records start, and when
  00000000000000000801.log      records 801..    <- the active segment
  00000000000000000801.idx
  snapshot                      whatever you last handed to `snapshot`
  reports.cursor                where the named reader `reports` got to
```

A segment is named for the sequence number of its first record, zero-padded to
twenty digits so the directory sorts in sequence order, and its first line says
what the file is. The segment a number is in comes from the names, and where
inside it to start reading comes from the index: a few reads and then at most
`Options.index_interval_bytes` of the segment. A log `compact` empties still
knows where it got to, because the empty segment left behind is named for the
record that comes next. Segments rotate at `Options.max_segment_bytes` or
`Options.max_segment_records`, on the append that would overflow the current
one, with no background thread.

`open` reads the index of each sealed segment, which says how many records it
holds and what the lowest and highest timestamp in it are, and that is what
proves the sequence runs without a gap; a segment whose index does not describe
it is read instead. The newest segment is read through unless it was closed
cleanly, in which case its index describes it at exactly its current length —
which is also a proof that it ends at a record boundary, so the repair pass is
skipped with it.

The index is a cache. Its header names the segment it was built from, that
segment's length and record count, the lowest and highest timestamp in it,
whether those timestamps rise, and a checksum of its own entries; anything that
disagrees, an older format included, is rebuilt from the segment. Deleting
every `.idx` file costs one scan per segment. By default it holds one entry per
4096 bytes of segment rather than one per record — a fortieth of the size, and
a bounded walk after the seek. `Options.index_interval_bytes = 0` is one entry
per record.

**Five promises, and nothing more.**

1. **A sequence number that `append` returned is on the disk**, as far as
   `Options.sync` asks, and one `appendDeferred` returned is once the next
   flush is. The record is serialised, written, flushed and made
   durable before `append` returns, before any sink is called and before any
   `waitPast` is woken, so a reader never sees a record the disk does not
   have — unless the writer deferred it, and then the operating system has
   it.

   | `Options.sync` | What a returned sequence number means | What that survives |
   |---|---|---|
   | `.always` (default) | The record's bytes have been through the flush in the table below. | A process crash. A power cut, as far as that flush reaches. |
   | `.on_segment` | The bytes reached the operating system, and go through that flush when the segment is sealed and when the journal is closed. | A process crash, including a kill. A power cut loses the records written since the last seal. |
   | `.never` | The bytes reached the operating system, and nothing asks it when it will write them back. | A process crash, including a kill. A power cut loses whatever had not been written back. |

   What "durable" costs is the platform's answer and not this package's, so it
   is stated per platform. `chronicle.flush` is the same three answers in code.

   | Platform | The call | What it means |
   |---|---|---|
   | macOS | `fcntl(F_FULLFSYNC)` | The drive was asked to flush its own cache to the media. `fsync` there returns before that, which is why it is not what this package uses — and why an `append` at `.always` costs milliseconds on a consumer drive rather than microseconds. A filesystem that will not take the call falls back to `fsync`, and then this row is the Linux row. |
   | Linux | `fdatasync` for a write into space the file already had, `fsync` otherwise | The bytes and what a reader needs to find them are with the drive. Whether the drive has them on its media is the drive's promise; `Options.preallocate_bytes` is what makes the cheaper of the two calls sufficient. |
   | Windows | `NtFlushBuffersFile` | The bytes are with the drive, on the same terms. |

   The policy governs the record bytes. The flushes that make a replacement
   atomic — promises 3 and 4 — are not optional under any of the three, because
   they are what those promises are.

   `appendDeferred` asks for less, record by record: the record is written,
   handed to the operating system and published at once, and made durable
   with whatever flushes the file next — an `append` or `appendAll` under
   `.always`, a rotation, a snapshot, a close. It is group commit where the
   caller knows which of its records must be on the disk before it acts and
   which may ride with the next one that must. A process crash loses none of
   them; a power cut may lose the deferred records since the last flush, and
   only those, since the file is written in order and a flush is of the whole
   file: what it can take is a suffix, never a gap.

2. **A failure to reach the disk is loud and must be reconciled.** A failed
   write, flush or `fsync` returns its error, calls no sink and makes every
   later `append` return `error.PersistenceFailed`. A complete record may have
   reached the file before a flush reported failure; `reconcile` reads the
   authoritative bytes back, repairs a partial line, reports the newest
   sequence that survived and clears the latch. Reopening does the same work.
3. **`snapshot`, `compact` and a tailer's cursor replace a file, never edit
   one.** Each writes a complete neighbouring file, flushes and `fsync`s it,
   then renames it into place, so a crash leaves either the whole old file or
   the whole new one. `compact` lets go of the segment it is replacing before
   the rename, because Windows refuses to rename over a file this process has
   open; a crash between rename and unlink leaves a segment the next `open`
   recognises and removes.
4. **A name that has been created or renamed is `fsync`ed too.** After a new
   segment, a renamed snapshot, a renamed segment or a dropped one, the
   journal's directory is `fsync`ed, so a power cut cannot leave a file whose
   contents reached the disk but whose name did not. Directories cannot be
   `fsync`ed on Windows; there this promise is the operating system's.
5. **A record that does not read back as it was written is named, not
   returned.** Every record carries a CRC32C of its own bytes, checked before
   the event is parsed on every path that turns a line into a record: `open`,
   `replay`, `subscribe`, `verify`. An unfinished line is
   `error.TruncatedRecord`; one whose bytes have changed since is
   `error.ChecksumMismatch`. Every record also carries the checksum of the
   record before it, so a record spliced in from somewhere else — or left over
   from an earlier life of a file — is `error.BrokenChain` rather than a fold
   that is quietly wrong. A segment file whose first line is not one this
   version writes is `error.UnsupportedFormat`, and so is a snapshot or a
   cursor from a shape it does not know. `Options.verify = .full` makes `open`
   check every record of every segment rather than only the newest, and
   `verify()` does the same on demand.

`appendAll` is group commit and not a transaction. A batch goes down under one
flush instead of one each, and a crash inside it leaves a prefix on the disk,
with a torn final line at worst — the shape a crash inside a single `append`
leaves, repaired the same way at the next open. If a group has to be
all-or-nothing to your fold, say so in the records. A snapshot is only ever an
optimisation, so deleting one costs replay time; an index is only ever a cache,
so losing one costs a scan.

**Record-sized working memory is bounded.** The tail is
`Options.tail_records` records and `Options.tail_bytes` bytes of them,
whichever bites first, kept parsed for `records`, `since` and `waitPast`; the
oldest half goes when either ceiling is reached, so a tail costs a constant
amount per append. A `Replay`, and so a `subscribe`, holds the record it is on
and one read buffer, `Options.read_buffer_size`; a line longer than
`Options.max_record_bytes` is refused rather than held. `open` walks the
newest segment's newlines, and the records in it land in the tail under its
ceilings. The journal also keeps fixed-size metadata for every segment, and a
replay snapshots two numbers per segment it will visit, so that memory grows
with the segment count even though it does not grow with the records inside a
segment. Every allocation comes from the allocator passed to `open`.

A `Record` from a `Window` lasts until the tail releases it, which the next
`append` may do; one from a `Replay` until the next `next`; one handed to a
`Sink` for the call. Copy what you need — `record.bytes` is the durable form,
ready to forward with no re-encoding.

**The writer holds an exclusive advisory lock on `<path>/lock` for as long as
it is open.**

| Situation | What holds |
|---|---|
| One writer | A second `open` with the default `Options.access = .write` gets `error.Locked`. The lock is released on close, and by the operating system when the process ends however it ends, including a kill. |
| Any number of readers | `Options.access = .read` takes no lock and writes nothing to the log: no repair, no index, no compaction. A record the writer is halfway through appending is the end of the log to a reader, not damage. |
| Tailing | `replay(cursor)` costs a seek and then the records; `refresh` re-reads the directory when the writer may have rotated, which costs a walk of the newest segment. `tailer(name)` keeps the cursor in `<path>/<name>.cursor` — the one file a `.read` journal writes, and its own rather than the log's. |
| `backup(dest)` beside a live writer | A read-only journal refreshes its segment inventory first, and the newest segment's length is measured and its newlines walked during the call, so the copy ends at a record boundary however far the writer had got. A reader omits the optional snapshot because it cannot freeze that file and the segments together; a writer's backup includes it. A writer unlinking a segment mid-copy comes back as an error rather than as a copy with a hole in it. |
| Two writers without the lock | Not available: this package gives no way to ask for it. A journal on a filesystem whose locks do not work is refused too — `open` returns `error.FileLocksUnsupported`. |
| Cross-process wake-up | Not promised. `waitPast` is for tasks inside one process; across processes, poll. |

**Every record carries the version it was written at, compared on the way back
against `Options.schema_version`.** Equal is parsed as `Event`. Newer is
`error.NewerSchema`: this process is the old one, and guessing at a record a
newer writer wrote is how a fold silently goes wrong. Older goes to
`Options.migrate` if you gave one, then to the `Event` arm named `unknown` if
there is one, typed `void` or `std.json.Value`, then to `error.OlderSchema`.
`compact` copies kept records byte for byte, so one read back through
`migrate` or the `unknown` arm keeps the version and payload it was written
with.

**One mutex inside.** `append`, `appendAll`, `waitPast`, `nudge`, `subscribe`,
`subscribeFrom`, `subscribeAll`, `subscribeAllFrom`, `unsubscribe`, `lastSeq`,
`seqAtOrAfter`, `tailer`, `readers`, `minCursor`, `snapshot`, `backup`,
`compact`, `dropSegmentsBefore`, `truncateAfter` and `refresh` take it and are
safe from any task or thread, several at once; the subscribe calls hold it for
the whole of their replay, so the hand-over from the disk to the live records
has no seam in it. A cancel reaches those calls at the lock: waiting for it,
a call returns `error.Canceled` with nothing done. Once a call that changes
the files holds it — an append, a batch, a snapshot, a compaction, a
truncation, a drop, a reconcile, a refresh — it runs to its end with the
task's cancelation blocked, and the cancel is reported by the task's next
cancelation point: a record a cancel landed on is written whole, never
latched as a write that failed. So is a close. A `Replay` takes no lock and writes nothing, so a segment
whose index is missing is walked from its first record rather than indexed on
the way; the calls above are what build an index. `records()`, `since()`,
`segmentCount()`, `oldestSeq()` and a `Replay` do not take it: call them from
the task that appends, or under coordination of your own. Every file operation
and the wait primitive go through `std.Io`, so the package runs under
`std.testing.io`, a threaded `Io`, or whatever comes next.

**A segment file begins with one line saying what it is, and then holds one
record per line, newline-terminated, in the field order written:**

```
{"chronicle":<u32>,"base":<u64>,"root":<u32>}
{"seq":<u64>,"at":<i64>,"v":<u32>,"p":<u32>,"ev":<your event as std.json>,"c":<u32>}
```

`chronicle` is the version of this framing, and a file whose first line is not
one this version knows is `error.UnsupportedFormat` rather than a file read as
though its records were these. `base` is the sequence number the file starts
at, which is also its name. `root` is the number the first record in the file
carries as its `p`: a random one for a file whose predecessors are gone, and
the last record of the previous file otherwise, so the chain below runs across
a rotation and across a compaction.

`seq` starts at 1 and rises by one, up to 2^63-1: a sequence number is a JSON
integer, and `append` refuses with `error.SequenceExhausted` rather than write
one that cannot be read back. `at` is whatever you passed, milliseconds since
the Unix epoch being the intended unit; chronicle never reads a clock, so a
test is deterministic and a replay exact. `v` is `Options.schema_version`. `p`
is the checksum of the record before this one. `c` is the CRC32C of every byte
of the line before the `,"c":` that carries it — the record with its closing
brace removed — written as a decimal integer and always last, which is what
makes it checkable without re-encoding anything. `chronicle.checksum` is that
function, public so a tool reading a segment with something other than this
package can check one; because `p` is inside the bytes it covers, one line can
still be checked on its own.

A snapshot lives at `<path>/snapshot`, and a named reader's cursor at
`<path>/<name>.cursor`, where `name` is one path component of at most
sixty-four letters, digits, `-` and `_`:

```
{"fmt":<u32>,"seq":<u64>,"state":"<your bytes, base64>"}
{"fmt":<u32>,"seq":<u64>}
```

`fmt` is the version of the document, and one this version does not know is
`error.UnsupportedFormat`. The snapshot's state is base64 rather than raw JSON
so a fold may serialise to anything — a packed struct, a cache file — without
the format having an opinion about it. Its `seq` is the journal's newest
sequence number at the moment it was taken: restore the state, then replay only
the records after it.

An index is a ninety-six-byte header, all of it little-endian: the magic
`chridx\x03\n`, then the segment length it describes as a `u64` — zero while
that segment is still being appended to — the lowest and highest `at` in the
segment as `i64`s, the segment's first sequence number and its record count as
`u64`s, the bytes of segment one entry covers as a `u32`, one `u32` of flags
whose lowest bit says the timestamps do not fall, thirty-six spare bytes that
are zero, and the CRC32C of the entries as a `u32`. Then the entries, each
twenty-four bytes: a record's sequence number as a `u64`, its byte offset as a
`u64` and its `at` as an `i64`. The timestamps are what `seqAtOrAfter` reads:
where a segment's flag says they do not fall they are bisected, and where it
does not they are read, because nothing makes a caller pass them in order.
Either way a segment whose highest is below the moment is skipped without its
file being opened.

## Scope

- **No query and no secondary indexes.** A range of sequence numbers, a lookup
  by time, and your fold.
- **No automatic retention.** `dropSegmentsBefore` and `compact` are the calls
  that drop history, and you decide when; `minCursor` is what the readers have
  consumed, if that is how you want to decide.
- **No encryption and no compression.** A record is stored as it was written.
- **No replication and no network protocol.** A journal is a local directory.
- **No hardening against a hostile file.** Records go through `std.json` with
  its defaults; the file contents this package survives are the ones a crash
  produces, not the ones an attacker chooses.

## Platforms

| Platform | Mechanism | Tested where |
|---|---|---|
| Linux | `flock`, directory `fsync`, `fdatasync`, `copy_file_range` | `test (ubuntu-latest)` on the CI runner |
| macOS | `flock`, directory `fsync`, `F_FULLFSYNC`, `clonefileat` | `test (macos-latest)` on the CI runner |
| Windows | `NtLockFile`; no directory `fsync` | `test (windows-latest)` on the CI runner |

Locking goes through `std.Io`, which uses `NtLockFile` on Windows and `flock`
on POSIX. The flush a durable write makes is in the Durability table above.
Durability promise 4 — that a created or renamed name is itself durable — has
no Windows equivalent and is the operating system's there. The copy a backup
makes is the filesystem's where the platform has a call for it and this
package's byte copy where it does not; the copy that lands is the same.

`zig build check -Dtarget=…` compiles everything, tests included, without
running it. CI does that for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`, with `x86_64-linux-gnu` and
`aarch64-linux-gnu` built a second time at a raised baseline — `x86_64_v2` and
`cortex_a72` — because the CRC32C instructions are chosen from the target's
features at compile time, so a baseline build takes the table and only a raised
one compiles the other arm. [`ci/linux.sh`](ci/linux.sh) runs the suite on
Linux in Docker from any machine; it is a local script and no CI job calls
it.

## Testing

```
zig build test          # the suite, and the examples, which are run
zig build examples      # the examples on their own
zig build check         # compile everything, including the tests, run nothing
zig build test --fuzz   # the fuzz tests, without a time limit
zig fmt --check src examples build.zig
ci/linux.sh             # the suite on Linux, in Docker, from any machine
```

Every test runs under `std.testing.allocator` and `std.testing.io`, against
real directories, in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. The
crash shapes are made on the disk rather than simulated: a torn final line, a
torn line in a sealed segment, a missing index, an index for the wrong bytes,
an index in an older format, a segment in an older framing, a record that does
not link to the one before it, a `.tmp` file a crash left behind, a byte
flipped inside a record that still parses, space a writer reserved and never
filled, a batch cut off at every byte boundary in it, and the two segments a
compaction leaves when it dies between its rename and its unlink. Three tests
spawn a second process — one to hold the lock, one to append while a backup is
taken beside it, and one to be killed while it mutates the journal — and one
builds a journal of two hundred thousand records and asserts that opening it
is proportionate and that record-sized working memory is bounded.

The measurements this package is judged on are tests with budgets: a seek into
the segment being written to against one into a sealed segment, an open of a
log that was closed cleanly against the same open with the index deleted, five
folds over one pass against one fold, and — in ReleaseFast — the rates an
append and a replayed record run at. Ratios wherever a ratio will do, because
an absolute number says more about the machine than about the package.

Six fuzz tests. Five run over the contents of a file — arbitrary segment bytes,
an arbitrary first line of a segment, an arbitrary index, an arbitrary snapshot
and an arbitrary cursor — where `open` must answer with a journal or a named
error, `.fail` must refuse a record the writer did not finish rather than drop
it and leave a file it refuses exactly as it found it, a `.drop` open followed
by an `append` must produce a log that opens again cleanly, and whatever an
index says, the records must be the ones the segments hold. The sixth runs over
the *calls*: a random run of `append`, `appendAll`, `compact`,
`truncateAfter`, `dropSegmentsBefore`, `backup` and `snapshot` in a child
process, killed after a fuzzed delay while that run is still executing. The
surviving log must open with every checksum good and every record linked to the
one before it, and go on from there.
Under `zig build test` each runs its corpus and stops, which costs
milliseconds, and the last one also runs sixty-four sequences from a fixed
seed.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).
