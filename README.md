# zjournal

[![CI](https://github.com/pedronaugusto/zjournal/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zjournal/actions/workflows/ci.yml)

An append-only, replayable event log for Zig. One JSON line per event, with a
sequence number, durable on disk, folded into state by any number of readers,
with snapshots to bound replay.

```
{"seq":1,"at":1700000000000,"v":1,"ev":{"account_opened":{"id":1,"owner":"ada"}}}
{"seq":2,"at":1700000000100,"v":1,"ev":{"deposited":{"id":1,"cents":5000}}}
```

The file is the state: every screen, cache and projection is a fold of it, and
the same fold runs whether the records came off the disk at startup or arrived
a moment ago. `tail -f` is a debugger.

- **Pure Zig, zero dependencies.** No C, no build options, one module.
- **Generic over your event type.** `Journal(Event)` takes any type
  `std.json` can write and read back — a tagged union is the expected shape,
  because it gives each record a name on disk and an exhaustive `switch` in
  the fold.
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
    // Open the log. It is created if it is not there, and every record
    // already in it is read back; the sequence number continues from the
    // last one, so a restart never reuses a number.
    var ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
    defer ledger.deinit(io);

    // A sink is a fold. Subscribing hands it every record already on
    // disk and then every record appended, so the state is built the
    // same way whether it came from a file or from a live writer.
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

## The durability promises

Exactly these three, and nothing more:

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
   over the destination. A crash at any moment leaves either the whole old
   file or the whole new one. `compact` always keeps the newest record, so the
   sequence survives a reopen even when you ask it to keep nothing.

What that leaves open, stated rather than implied: zjournal does not `fsync`
the containing directory after a rename, so a power cut immediately after
`compact` may leave the filesystem presenting either file — both of which are
complete journals. And a snapshot is only ever an optimisation: deleting one
costs replay time and nothing else.

## What it does not do

- **No locking between processes.** One writer per file. zjournal does not
  take an advisory lock and does not detect a second writer; two processes
  appending to one journal will interleave partial lines.
- **No indexing, no query, no time travel.** `since(cursor)` is the whole
  read API. Everything else is your fold.
- **No log rotation, no retention policy, no size limit.** `compact` is
  manual, and you choose when and how far.
- **No streaming read.** `open` reads the whole file into memory and keeps
  every record there. A journal is expected to be compacted to a size that
  fits; if yours cannot be, this is the wrong package.
- **No encryption, no compression, no checksums.** A record is corrupt when
  it does not parse, which is not the same as a record being intact.
- **No clock.** `append` stores the `at` you pass. zjournal never reads the
  time, so a test is deterministic and a replay is honest.
- **No network, no server, no replication.** It is a file.

## The format

One record per line, newline-terminated, in the field order written:

```
{"seq":<u64>,"at":<i64>,"v":<u32>,"ev":<your event as std.json>}
```

`seq` starts at 1 and rises by one. `at` is whatever you passed; milliseconds
since the Unix epoch is the intended unit. `v` is `Options.schema_version`.

A snapshot lives beside the journal at `<path>.snapshot`:

```
{"seq":<u64>,"state":"<your bytes, base64>"}
```

The state is base64 rather than raw JSON so that a fold may serialise to
anything at all — a packed struct, a protobuf, a cache file — without the
snapshot format having an opinion about it. `seq` is the journal's newest
sequence number at the moment the snapshot was taken: restore the state, then
replay only the records after it.

## Schema versions

Every record carries the version it was written at, and `open` compares each
against `Options.schema_version`:

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
`subscribeFrom`, `lastSeq`, `snapshot` and `compact` take it and are safe to
call from any task or thread, including several at once.

`records()` and `since()` do not take it: call them from the task that
appends, or under coordination of your own. `waitPast` is the equivalent that
takes the lock, and a `Sink` is the way to consume from elsewhere.

Memory is an arena, and nothing in it is freed before `compact` or `deinit`.
That is what makes every slice a reader holds — a record, its `bytes`, any
string inside its event — stay valid until one of those two calls. Both
invalidate everything at once.

## The API

`zjournal.Journal(comptime Event: type)` returns a type with:

| | |
|---|---|
| `open(gpa, io, path, options)` | Create or read back a journal. |
| `openWithSnapshot(gpa, io, path, options)` | The same, plus the snapshot beside it. |
| `deinit(io)` | Flush, close, release. |
| `append(io, at, event)` | Write one record durably; returns its sequence number. |
| `records()` | Every record held, oldest first. |
| `since(cursor)` | The records after `cursor`. |
| `waitPast(io, cursor)` | Block until there is one, then `since(cursor)`. |
| `nudge(io)` | Wake the waiters with no record behind it. |
| `lastSeq(io)` | The newest sequence number, or zero. |
| `subscribe(io, sink)` | Fold every record, from the disk and then live. |
| `subscribeFrom(io, sink, cursor)` | The same, starting after a snapshot. |
| `snapshot(io, state_bytes)` | Write the fold out beside the log. |
| `compact(io, keep_after_seq)` | Rewrite the log, keeping the tail. |

Plus the types `Record`, `Sink`, `Options`, `Snapshot`, `Opened`, `Migrate`,
and one named error set per operation. Every public declaration carries a doc
comment stating its contract; `src/zjournal.zig` is the reference.

## Testing

```
zig build test        # the suite, and the examples, which are run
zig build examples    # the examples on their own
zig fmt --check src examples build.zig
```

Every test runs under `std.testing.allocator` and `std.testing.io`, against
real files in a temporary directory, in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall.

## License

MIT. See [LICENSE](LICENSE).
