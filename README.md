# zjournal

[![CI](https://github.com/pedronaugusto/zjournal/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zjournal/actions/workflows/ci.yml)

An append-only, replayable event log for Zig. One JSON line per event, with a
sequence number, durable on disk, folded into state by any number of readers,
segmented so that a daemon can run on it for a year.

```
{"seq":1,"at":1700000000000,"v":1,"ev":{"account_opened":{"id":1,"owner":"ada"}}}
{"seq":2,"at":1700000000100,"v":1,"ev":{"deposited":{"id":1,"cents":5000}}}
```

The log is the state: every screen, cache and projection is a fold of it, and
the same fold runs whether the records came off the disk at startup or arrived
a moment ago. `tail -f` is a debugger.

- **Pure Zig, zero dependencies.** No C, no build options, one module.
- **Generic over your event type.** `Journal(Event)` takes any type
  `std.json` can write and read back — a tagged union is the expected shape,
  because it gives each record a name on disk and an exhaustive `switch` in
  the fold.
- **Bounded memory, unbounded history.** `open` reads the newest segment and
  one line of each older one. Folding streams from the disk, a record at a
  time. What memory holds is a tail you size.
- **Segments, an index and a lock.** The log rotates into files named after
  the record they start with, a sidecar index turns a cursor into a seek, and
  an advisory lock means a second writer is told `error.Locked` rather than
  interleaving half-records into yours.
- **Crash-shaped by design.** The sequence continues across restarts, a final
  line a dying writer did not finish is detected and repaired, a write that
  does not reach the disk publishes nothing and latches, and schema drift in
  both directions is an error you can name rather than a wrong answer.
- **Everything through `std.Io`.** Every file operation and the wait
  primitive, so the package runs under `std.testing.io`, a threaded `Io`, or
  whatever comes next.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds
and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a
README is a claim about how the library is used, and this one is a claim
something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const zjournal = @import("zjournal");

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
    _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 5_000 } });
    last = try ledger.append(io, now, .{ .withdrawn = .{ .id = 1, .cents = 1_250 } });

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

Add it as a dependency and link the module:

```zig
const zjournal_dep = b.dependency("zjournal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zjournal", zjournal_dep.module("zjournal"));
```

## What is on the disk

A journal is a directory, and `path` names it:

```
ledger/
  lock                          zero bytes; the writer's advisory lock
  00000000000000000001.log      records 1..800
  00000000000000000001.idx      one byte offset per record
  00000000000000000801.log      records 801..    <- the active segment
  00000000000000000801.idx
  snapshot                      whatever you last handed to `snapshot`
```

A segment's name is the sequence number of its first record, zero-padded to
twenty digits so that the directory sorts in sequence order. That one decision
does most of the work here:

- **A cursor is a lookup, not a scan.** The segment a sequence number is in is
  found from the names, and the byte offset inside it from the index, so
  reading from the middle of a year of records costs two reads.
- **`open` costs one segment.** Only the newest one is read through; every
  older one gives up its last record in a single read, which is enough to
  prove the sequence runs without a gap from the first record to the last.
- **The sequence survives an empty log.** `compact` asked to keep nothing
  leaves one empty segment named for the record that comes next, so the
  numbering continues with no record left to carry it.

The index is a cache and is treated as one: a header naming the segment length
it was built from, then one little-endian `u64` per record. It is checked
against that length and against the sequence number of the record at its last
offset, and anything that disagrees is rebuilt from the segment. Deleting every
`.idx` file costs one scan per segment and nothing else.

## The durability promises

Exactly these four, and nothing more:

1. **A sequence number that `append` returned is on the disk.** The record is
   serialised, written, flushed and — unless you set `Options.fsync = false` —
   `fsync`ed before `append` returns, before any sink is called and before any
   `waitPast` is woken. A reader therefore never sees a record the disk does
   not have. With `fsync` off the promise weakens to "the bytes reached the
   operating system", which survives a process crash but not a power cut.
2. **A failure to reach the disk is permanent and loud.** If the write, the
   flush or the `fsync` fails, `append` returns that error, adds no record,
   calls no sink, and every later `append` returns
   `error.PersistenceFailed` — because once one record is missing, every later
   record is a lie about the order. Reopen the journal to resume: `open`
   repairs the partial line the failed write may have left.
3. **`snapshot` and `compact` replace a file, never edit one.** Each writes a
   complete neighbouring file, flushes and `fsync`s it, and then renames it
   into place. A crash at any moment leaves either the whole old file or the
   whole new one. `compact` lets go of the segment it is replacing before the
   rename, because Windows refuses to rename over a file this process has
   open, and a crash between the rename and the unlink leaves a segment the
   next `open` recognises and removes.
4. **A name that has been created or renamed is `fsync`ed too.** After a new
   segment, a renamed snapshot, a renamed segment or a dropped one, the
   journal's directory is itself `fsync`ed, so a power cut cannot leave a file
   whose contents reached the disk but whose name did not. Directories cannot
   be `fsync`ed on Windows; there this promise is the operating system's and
   not this package's.

What that leaves open, stated rather than implied: a snapshot is only ever an
optimisation, so deleting one costs replay time and nothing else; and an index
is only ever a cache, so losing one costs a scan.

**Windows is compiled but unverified.** Every target below cross-compiles, and
CI runs the suite on a Windows runner, but the author has not watched the
atomic replacement or the lock behave on a real NTFS volume. The lock goes
through `std.Io`, which uses `NtLockFile` there and `flock` on POSIX. Treat
every promise as proved on Linux and macOS — `ci/linux.sh` runs the suite in a
container on each release — and claimed on Windows.

## More than one process

The writer holds an exclusive advisory lock on `<path>/lock` for as long as it
is open. What follows from that:

- **Safe.** One writer. A second `open` with the default
  `Options.access = .write` returns `error.Locked` rather than corrupting
  anything. The lock is released when the journal is closed, and by the
  operating system when the process ends however it ends — including a kill.
- **Safe.** Any number of readers, in any number of processes, opened with
  `Options.access = .read`. Such a journal takes no lock, so it never keeps the
  writer out, and writes nothing at all: no repair, no index, no compaction. A
  record the writer is halfway through appending is the end of the log to a
  reader, not damage.
- **Safe.** Tailing. A reader calls `replay(cursor)` for the records after the
  cursor, which costs a seek and then the records themselves; when the writer
  may have started a new segment, `refresh` re-reads the directory first, which
  costs a walk of the newest segment.
- **Not safe.** Two writers without the lock — which this package gives you no
  way to ask for. Nor is a journal on a filesystem whose locks do not work:
  `open` returns `error.FileLocksUnsupported` rather than pretending.
- **Not promised.** A reader is not woken by a writer in another process.
  `waitPast` is for tasks inside one process; across processes, poll.

## What it does not do

- **No query, no time travel, no secondary indexes.** The index maps a
  sequence number to a byte offset and nothing else. Everything past that is
  your fold.
- **No automatic retention.** Segments rotate on their own; nothing is ever
  deleted on your behalf. `dropSegmentsBefore` unlinks whole segments and
  `compact` rewrites across one, and you decide when.
- **No encryption, no compression, no checksums.** A record is corrupt when it
  does not parse, which is not the same as a record being intact.
- **No hardening against a hostile file.** Records go through `std.json` with
  its defaults. A journal is written by the program that owns it; the file
  contents this package is built to survive are the ones a crash produces, not
  the ones an attacker chooses.
- **No clock.** `append` stores the `at` you pass. zjournal never reads the
  time, so a test is deterministic and a replay is honest.
- **No network, no server, no replication.** It is a directory.

## The format

One record per line, newline-terminated, in the field order written:

```
{"seq":<u64>,"at":<i64>,"v":<u32>,"ev":<your event as std.json>}
```

`seq` starts at 1 and rises by one, up to 2^63-1 — a sequence number is a JSON
integer, and `append` refuses with `error.SequenceExhausted` rather than write
one that cannot be read back. `at` is whatever you passed; milliseconds since
the Unix epoch is the intended unit. `v` is `Options.schema_version`.

A snapshot lives at `<path>/snapshot`:

```
{"seq":<u64>,"state":"<your bytes, base64>"}
```

The state is base64 rather than raw JSON so that a fold may serialise to
anything at all — a packed struct, a protobuf, a cache file — without the
snapshot format having an opinion about it. `seq` is the journal's newest
sequence number at the moment the snapshot was taken: restore the state, then
replay only the records after it.

An index is a sixteen-byte header — the magic `zjidx\0\x01\n`, then the
segment length it describes as a little-endian `u64`, zero while that segment
is still being appended to — followed by one little-endian `u64` per record.

## Memory

Three things, and each of them is bounded by something you set:

- **The tail.** `Options.tail_records` records and `Options.tail_bytes` bytes
  of them, whichever bites first, kept parsed in memory for `records`, `since`
  and `waitPast`. The oldest half is released when either ceiling is reached,
  which is why keeping a tail costs a constant amount per append.
- **One record.** A `Replay`, and so a `subscribe`, holds the record it is on
  and the one read buffer it streams through — `Options.read_buffer_size`.
- **One segment, at open.** Only to walk its newlines; the records inside it
  go into the tail and are subject to its ceilings.

Nothing here grows with the length of the log.

## Schema versions

Every record carries the version it was written at, and every record that is
read back is compared against `Options.schema_version`:

- **Equal** — parsed as `Event`.
- **Newer** — `error.NewerSchema`. This process is the old one; guessing at a
  record a newer writer wrote is how a fold silently goes wrong.
- **Older** — passed to `Options.migrate` if you gave one. Failing that, it
  becomes the `Event` arm named `unknown` if there is one, typed either `void`
  or `std.json.Value`, so a reader that only needs to count records does not
  have to understand every record. Failing that too, `error.OlderSchema`.

`compact` copies kept records byte for byte, so a record read back through
`migrate` or the `unknown` arm keeps the version and the payload it was
written with.

## Threads and tasks

One mutex inside. `append`, `waitPast`, `nudge`, `subscribe`,
`subscribeFrom`, `lastSeq`, `snapshot`, `compact`, `dropSegmentsBefore` and
`refresh` take it and are safe to call from any task or thread, including
several at once. `subscribeFrom` holds it for the whole of its replay, so the
hand-over from the disk to the live records has no seam in it.

`records()`, `since()`, `segmentCount()`, `oldestSeq()` and a `Replay` do not
take it: call them from the task that appends, or under coordination of your
own. `waitPast` is the locked equivalent of `since`, and a `Sink` is the way
to consume from elsewhere.

A `Record` from a `Window` lives in the tail, so it lasts until the tail
releases it — which the next `append` may do. A `Record` from a `Replay` lasts
until the next `next`. A `Record` handed to a `Sink` lasts for the call. Copy
what you need to keep; `record.bytes` is the durable form, ready to forward
with no re-encoding.

## The API

`zjournal.Journal(comptime Event: type)` returns a type with:

| | |
|---|---|
| `open(gpa, io, path, options)` | Create or read back a journal directory. |
| `openWithSnapshot(gpa, io, path, options)` | The same, plus the snapshot beside it. |
| `deinit(io)` | Flush, close, unlock, release. |
| `append(io, at, event)` | Write one record durably; returns its sequence number. |
| `records()` | The tail, oldest first, as a `Window`. |
| `since(cursor)` | The tail after `cursor`, as a `Window`. |
| `waitPast(io, cursor)` | Block until there is one, then `since(cursor)`. |
| `replay(io, cursor)` | A walk over every record after `cursor`, from the disk. |
| `nudge(io)` | Wake the waiters with no record behind it. |
| `lastSeq(io)` | The newest sequence number, or zero. |
| `oldestSeq()` | The oldest one still held. |
| `segmentCount()` | How many files the log is spread over. |
| `refresh(io)` | Read the directory again — how a reader tails a writer. |
| `subscribe(io, sink)` | Fold every record, from the disk and then live. |
| `subscribeFrom(io, sink, cursor)` | The same, starting after a snapshot. |
| `snapshot(io, state_bytes)` | Write the fold out beside the log. |
| `compact(io, keep_after_seq)` | Rewrite the log, keeping the records after the cut. |
| `dropSegmentsBefore(io, seq)` | Unlink the whole segments a snapshot covers. |

Plus the types `Record`, `Window`, `Replay`, `Sink`, `Options`, `Snapshot`,
`Opened`, `Migrate`, and one named error set per operation. Every public
declaration carries a doc comment stating its contract; `src/zjournal.zig` is
the reference, and `src/log.zig` is the segment store under it.

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
real directories in a temporary one, in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall. What they cover beyond the happy path is the crash shapes, made
on the disk rather than simulated: a torn final line, a torn line in a sealed
segment, a missing index, an index for the wrong bytes, a `.tmp` file a crash
left behind, and the two segments a compaction leaves when it dies between its
rename and its unlink. One test spawns a second process to hold the lock,
because `error.Locked` is not a claim a single process can prove. One builds a
journal of two hundred thousand records and asserts that opening it is
proportionate and that memory is not.

Three of them are fuzz tests, over arbitrary segment, index and snapshot file
contents: `open` must answer with a journal or a named error, the `.fail` mode
must leave the file exactly as it found it, a `.drop` open followed by an
`append` must produce a log that opens again cleanly, and whatever an index
says, the records must be the ones the segments hold. Under `zig build test`
they run their corpus and stop, which costs milliseconds.

## License

MIT. See [LICENSE](LICENSE).
