# chronicle

[![CI](https://github.com/pedronaugusto/chronicle/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/chronicle/actions/workflows/ci.yml)

An append-only event log for Zig. A journal is a directory of segment files
holding one JSON object per line, each with a sequence number, a timestamp and
a schema version; a program folds those records into whatever state it needs,
from the disk at startup and live afterwards.

```
{"seq":1,"at":1700000000000,"v":1,"ev":{"account_opened":{"id":1,"owner":"ada"}},"c":266789872}
{"seq":2,"at":1700000000100,"v":1,"ev":{"deposited":{"id":1,"cents":5000}},"c":611212677}
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
| `deinit(io)` | Flush, close, unlock, release. |
| `append(io, at, event)` | Write one record durably; returns its sequence number. |
| `appendAll(io, entries)` | Write a batch under one `fsync`; returns the last sequence number. |
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
| `snapshot(io, state_bytes)` | Write the fold out beside the log. |
| `backup(io, dest)` | Copy the journal into another directory while it runs. |
| `compact(io, keep_after_seq)` | Rewrite the log, keeping the records after the cut. |
| `dropSegmentsBefore(io, seq)` | Unlink the whole segments a snapshot covers. |
| `truncateAfter(io, seq)` | Drop every record after `seq`, handing the numbers back. |
| `verify(io)` | Read every record of every segment through every check. |
| `stats(io)` | Segments, records, and the bytes they take. |

Plus the types `Record`, `Entry`, `Window`, `Replay`, `Tailer`, `Sink`,
`Options`, `Snapshot`, `Opened`, `Migrate`, `Stats`, `Sync`, `Verify`, and one
named error set per operation. Every public declaration carries a doc comment
stating its contract; `src/chronicle.zig` is the reference and `src/log.zig`
the segment store under it. `Event` may be any type `std.json` can write and
read back; a tagged union is the expected shape, because it gives each record a
name on disk and an exhaustive `switch` in the fold.

## Design

### What is on the disk

```
ledger/
  lock                          zero bytes; the writer's advisory lock
  00000000000000000001.log      records 1..800
  00000000000000000001.idx      a byte offset and a timestamp per record
  00000000000000000801.log      records 801..    <- the active segment
  00000000000000000801.idx
  snapshot                      whatever you last handed to `snapshot`
  reports.cursor                where the named reader `reports` got to
```

A segment is named for the sequence number of its first record, zero-padded to
twenty digits so the directory sorts in sequence order. The segment a number is
in comes from the names and the offset inside it from the index, so reading
from the middle of a year of records costs two reads; `open` reads the newest
segment through and takes one record from each older one, which proves the
sequence runs without a gap; and a log `compact` empties still knows where it
got to, because the empty segment left behind is named for the record that
comes next. Segments rotate at `Options.max_segment_bytes` or
`Options.max_segment_records`, on the append that would overflow the current
one, with no background thread.

The index is a cache. Its header names the segment length it was built from and
the lowest and highest timestamp in it, and is checked against that length and
against the sequence number of the record at its last offset; anything that
disagrees, an older format included, is rebuilt from the segment. Deleting
every `.idx` file costs one scan per segment.

### Durability

Five promises, and nothing more.

1. **A sequence number that `append` returned is on the disk**, as far as
   `Options.sync` asks. The record is serialised, written, flushed and made
   durable before `append` returns, before any sink is called and before any
   `waitPast` is woken, so a reader never sees a record the disk does not have.

   | `Options.sync` | What a returned sequence number means | What that survives |
   |---|---|---|
   | `.always` (default) | The record's bytes have been `fsync`ed. | A process crash, and a power cut. |
   | `.on_segment` | The bytes reached the operating system, and are `fsync`ed when the segment is sealed and when the journal is closed. | A process crash, including a kill. A power cut loses the records written since the last seal. |
   | `.never` | The bytes reached the operating system, and nothing asks it when it will write them back. | A process crash, including a kill. A power cut loses whatever had not been written back. |

   The policy governs the record bytes. The `fsync`s that make a replacement
   atomic — promises 3 and 4 — are not optional under any of the three, because
   they are what those promises are.

2. **A failure to reach the disk is permanent and loud.** A failed write, flush
   or `fsync` returns its error, adds no record and calls no sink, and every
   later `append` returns `error.PersistenceFailed`: once one record is
   missing, every later one is a lie about the order. Reopening resumes and
   repairs the partial line.
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
   `error.ChecksumMismatch`. `Options.verify = .full` makes `open` check every
   record of every segment rather than only the newest, and `verify()` does the
   same on demand. A record written before 0.3.0 carries no checksum and is
   read as it always was.

`appendAll` is group commit and not a transaction. A batch goes down under one
`fsync` instead of one each, and a crash inside it leaves a prefix on the disk,
with a torn final line at worst — the shape a crash inside a single `append`
leaves, repaired the same way at the next open. If a group has to be
all-or-nothing to your fold, say so in the records. A snapshot is only ever an
optimisation, so deleting one costs replay time; an index is only ever a cache,
so losing one costs a scan.

### Memory

Three things, each bounded by something you set. The tail is
`Options.tail_records` records and `Options.tail_bytes` bytes of them,
whichever bites first, kept parsed for `records`, `since` and `waitPast`; the
oldest half goes when either ceiling is reached, so a tail costs a constant
amount per append. A `Replay`, and so a `subscribe`, holds the record it is on
and one read buffer, `Options.read_buffer_size`. `open` walks the newest
segment's newlines, and the records in it land in the tail under its ceilings.
Nothing grows with the length of the log, and every allocation comes from the
allocator passed to `open`.

A `Record` from a `Window` lasts until the tail releases it, which the next
`append` may do; one from a `Replay` until the next `next`; one handed to a
`Sink` for the call. Copy what you need — `record.bytes` is the durable form,
ready to forward with no re-encoding.

### More than one process

The writer holds an exclusive advisory lock on `<path>/lock` for as long as it
is open.

| Situation | What holds |
|---|---|
| One writer | A second `open` with the default `Options.access = .write` gets `error.Locked`. The lock is released on close, and by the operating system when the process ends however it ends, including a kill. |
| Any number of readers | `Options.access = .read` takes no lock and writes nothing to the log: no repair, no index, no compaction. A record the writer is halfway through appending is the end of the log to a reader, not damage. |
| Tailing | `replay(cursor)` costs a seek and then the records; `refresh` re-reads the directory when the writer may have rotated, which costs a walk of the newest segment. `tailer(name)` keeps the cursor in `<path>/<name>.cursor` — the one file a `.read` journal writes, and its own rather than the log's. |
| `backup(dest)` beside a live writer | The newest segment's length is measured and its newlines walked during the call, so the copy ends at a record boundary however far the writer had got. A writer unlinking a segment mid-copy comes back as an error rather than as a copy with a hole in it. |
| Two writers without the lock | Not available: this package gives no way to ask for it. A journal on a filesystem whose locks do not work is refused too — `open` returns `error.FileLocksUnsupported`. |
| Cross-process wake-up | Not promised. `waitPast` is for tasks inside one process; across processes, poll. |

### Schema versions

Every record carries the version it was written at, compared on the way back
against `Options.schema_version`. Equal is parsed as `Event`. Newer is
`error.NewerSchema`: this process is the old one, and guessing at a record a
newer writer wrote is how a fold silently goes wrong. Older goes to
`Options.migrate` if you gave one, then to the `Event` arm named `unknown` if
there is one, typed `void` or `std.json.Value`, then to `error.OlderSchema`.
`compact` copies kept records byte for byte, so one read back through `migrate`
or the `unknown` arm keeps the version and payload it was written with.

### Threads and tasks

One mutex inside. `append`, `appendAll`, `waitPast`, `nudge`, `subscribe`,
`subscribeFrom`, `lastSeq`, `seqAtOrAfter`, `tailer`, `snapshot`, `backup`,
`compact`, `dropSegmentsBefore`, `truncateAfter` and `refresh` take it and are
safe from any task or thread, several at once; `subscribeFrom` holds it for the
whole of its replay, so the hand-over from the disk to the live records has no
seam in it. `records()`, `since()`, `segmentCount()`, `oldestSeq()` and a
`Replay` do not take it: call them from the task that appends, or under
coordination of your own. Every file operation and the wait primitive go
through `std.Io`, so the package runs under `std.testing.io`, a threaded `Io`,
or whatever comes next.

### The format

One record per line, newline-terminated, in the field order written:

```
{"seq":<u64>,"at":<i64>,"v":<u32>,"ev":<your event as std.json>,"c":<u32>}
```

`seq` starts at 1 and rises by one, up to 2^63-1: a sequence number is a JSON
integer, and `append` refuses with `error.SequenceExhausted` rather than write
one that cannot be read back. `at` is whatever you passed, milliseconds since
the Unix epoch being the intended unit; chronicle never reads a clock, so a
test is deterministic and a replay exact. `v` is `Options.schema_version`. `c`
is the CRC32C of every byte of the line before the `,"c":` that carries it —
the record with its closing brace removed — written as a decimal integer and
always last, which is what makes it checkable without re-encoding anything.
`chronicle.checksum` is that function, public so a tool reading a segment with
something other than this package can check one.

A snapshot lives at `<path>/snapshot`, and a named reader's cursor at
`<path>/<name>.cursor`, where `name` is one path component of letters, digits,
`-` and `_`:

```
{"seq":<u64>,"state":"<your bytes, base64>"}
{"seq":<u64>}
```

The snapshot's state is base64 rather than raw JSON so a fold may serialise to
anything — a packed struct, a cache file — without the format having an opinion
about it. Its `seq` is the journal's newest sequence number at the moment it
was taken: restore the state, then replay only the records after it.

An index is a thirty-two-byte header — the magic `chridx\x02\n`, then three
little-endian integers: the segment length it describes as a `u64`, zero while
that segment is still being appended to, and the lowest and highest `at` in the
segment as `i64`s — followed by one sixteen-byte entry per record: the record's
byte offset as a `u64` and its `at` as an `i64`. The timestamps are what
`seqAtOrAfter` reads. It does not bisect, because nothing makes a caller pass
its timestamps in order: every segment whose highest reaches the moment is
looked inside, oldest first, and one whose highest is below it is skipped
without its file being opened.

## Scope

Things a log of this kind might be expected to carry, and this one does not:

- **No query and no secondary indexes.** A range of sequence numbers, a lookup
  by time, and your fold.
- **No automatic retention.** `dropSegmentsBefore` and `compact` are the calls
  that drop history, and you decide when.
- **No encryption and no compression.** A record is stored as it was written.
- **No replication and no network protocol.** A journal is a local directory.
- **No hardening against a hostile file.** Records go through `std.json` with
  its defaults; the file contents this package survives are the ones a crash
  produces, not the ones an attacker chooses.

## Platforms

| Platform | Mechanism | Tested where |
|---|---|---|
| Linux | `flock`, directory `fsync` | `test (ubuntu-latest)` on the CI runner, and `ci/linux.sh` in Docker from any machine |
| macOS | `flock`, directory `fsync` | `test (macos-latest)` on the CI runner |
| Windows | `NtLockFile`; no directory `fsync` | `test (windows-latest)` on the CI runner |

Locking goes through `std.Io`, which uses `NtLockFile` on Windows and `flock`
on POSIX. Durability promise 4 — that a created or renamed name is itself
durable — has no Windows equivalent and is the operating system's there.

`zig build check -Dtarget=…` compiles everything, tests included, without
running it. CI does that for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

Every job in that matrix passed on run
[`34804414740`](https://github.com/pedronaugusto/chronicle/actions/runs/34804414740).

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
an index in the older format, a `.tmp` file a crash left behind, a byte flipped
inside a record that still parses, a record from before checksums existed, a
batch cut off at every byte boundary in it, and the two segments a compaction
leaves when it dies between its rename and its unlink. Two tests spawn a second
process — one to hold the lock, one to append while a backup is taken beside
it — and one builds a journal of two hundred thousand records and asserts that
opening it is proportionate and that memory is not.

Three fuzz tests run over arbitrary segment, index and snapshot file contents:
`open` must answer with a journal or a named error, `.fail` must leave the file
exactly as it found it, a `.drop` open followed by an `append` must produce a
log that opens again cleanly, and whatever an index says, the records must be
the ones the segments hold. Under `zig build test` they run their corpus and
stop, which costs milliseconds.

## Requirements

Zig 0.16.0.

## License

MIT. See [LICENSE](LICENSE).
