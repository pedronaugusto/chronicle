# chronicle

chronicle stores typed events in an append-only journal of JSON Lines segments. Sequence
numbers and chained CRC32C checksums let replay detect altered records and gaps before
folding them into state.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/chronicle`, then obtain the `chronicle` module
through `b.dependency` and add it to your executable's imports. Forward your target and
optimize settings.

## Usage

[examples/usage.zig](examples/usage.zig) defines `Ledger` as `chronicle.Journal(Event)`
and a `Balances` fold over account, deposit and withdrawal events. It opens the journal
at `path` with the supplied allocator and `std.Io`.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const chronicle = @import("chronicle");

var balances: Balances = .{};
var last: chronicle.Seq = chronicle.beginning;
{
    const ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
    defer ledger.deinit(io);

    try ledger.subscribe(io, balances.sink());

    const now = std.Io.Clock.real.now(io).toMilliseconds();
    _ = try ledger.append(io, now, .{ .account_opened = .{ .id = 1, .owner = "ada" } });

    const follower = try ledger.replayAt(io, .after(chronicle.beginning));
    defer follower.deinit(io);
    _ = (try follower.next(io)).?;

    last = try ledger.appendAll(io, &.{
        .{ .at = now, .event = .{ .deposited = .{ .id = 1, .cents = 5_000 } } },
        .{ .at = now, .event = .{ .withdrawn = .{ .id = 1, .cents = 1_250 } } },
    }, .group);
    try follower.rearmAt(io, follower.position());
    var followed: usize = 0;
    while (try follower.next(io)) |_| followed += 1;
    if (followed != 2) return error.ReplayMismatch;

    try ledger.snapshot(io, std.mem.asBytes(&balances));
    try ledger.compact(io, last);

    _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 700 } });
}

const opened = try Ledger.openWithSnapshot(gpa, io, path, .{ .schema_version = 1 });
const reopened = opened.journal;
defer reopened.deinit(io);

var restored: Balances = .{};
var from: chronicle.Seq = chronicle.beginning;
if (opened.snapshot) |snapshot| {
    defer snapshot.deinit();
    restored = std.mem.bytesToValue(Balances, snapshot.state[0..@sizeOf(Balances)]);
    from = snapshot.seq;
}
try reopened.subscribeFrom(io, restored.sink(), from);
```
<!-- END GENERATED -->

## Design

chronicle depends on a pinned strand package for record encoding and decoding. A journal
takes an allocator that must outlive it and owns a directory, active segment files, a
bounded in-memory tail and a mutex. Journal, replay, tailer, copied batch and
reader-list results are opaque pointer owners: release each exactly once. Release
replays and tailers before the journal. `finish` makes the active segment durable and
reports what failed, leaving the journal open; `deinit` releases it, writing the same as
best it can.

`append` takes the timestamp from the caller. With the default `sync = .always`, it
syncs the record before publishing it or returning its sequence number; `appendAll`
shares a record sync across a batch. A `.group` batch cut by a crash leaves a prefix; an
`.atomic` batch names its first and last records in each of its records, stays in one
segment, and is dropped whole by an open that finds the log ending inside it. Readers
beside the writer read an atomic batch only once it is whole. `appendIf` and
`appendAllIf` append only while the newest record is still the one the caller expected,
and otherwise return `error.WrongExpectedSeq` with the newest sequence number.
`appendDeferred` publishes before durability and requires a later flush. The
`.on_segment` policy syncs at sealing and at `finish`; `.never` leaves record writeback to the
operating system. Structural replacement flushes still apply under both policies.

Durable writes are [airlock](https://github.com/pedronaugusto/airlock)'s: `fcntl(F_FULLFSYNC)`
on macOS, `fsync` on Linux and `NtFlushBuffersFile` on Windows, with the data-only sync
(`fdatasync`, `NtFlushBuffersFileEx(DATA_SYNC_ONLY)` on NTFS) for writes into reserved
space. A filesystem that declines the call gets the strongest one it takes, and
`status().flushed` says what the records reached (`chronicle.flush` where nothing
declined). A new segment, a compaction, a snapshot and a cursor are each made durable
under their name, the directory included, on every platform: Windows flushes the
directory too. A snapshot, a cursor and a compacted segment are written under a
temporary name drawn at random and renamed into place; a writer's open removes the
temporaries a crash left once they are an hour old. A backup makes its copies durable
together, a writeout of each and one flush of the device on macOS and Windows.

Opening repairs an unfinished final record by default: a line with no newline, or one
whose newline reached the disk without all of its bytes, as a power cut can leave it.
`.on_truncated = .fail` refuses either. Damage before the final record is always refused.
Quick verification checks the active segment and older segment headers; full
verification checks the history. Failed persistence blocks later appends until
`reconcile` determines whether the attempted write survived. Schema versions newer than
the reader are refused; older records require a migration hook or an `unknown` arm.

`subscribe` streams disk history and then live appends through the same sink under the
journal lock. Sink records last for the callback, which must not call back into the
journal. Replay records last until the next read, re-arm or replay release. `position`
and `rearmAt` resume a replay after validating its prior record; changed history can
yield `StalePosition`. `copySince` returns an independent owned batch from the memory
tail; check `complete()` before treating it as the whole interval.

Snapshots store caller-supplied state bytes and the sequence they cover. Restore the
bytes, then replay after that sequence. Named tailers persist committed cursors.
Compaction, segment removal and backup are explicit calls; the journal does not decide
which history a reader may discard. [examples/migrate.zig](examples/migrate.zig)
exercises schema migration.

## Scope

- It does not provide transactions spanning journals, or across appends: one atomic
  batch is the unit that is all or nothing.
- It does not replicate a journal or coordinate writers across machines.
- It does not query event fields or build application indexes.
- It does not serialize the application's snapshot state for it.
- It does not choose retention policy or protect history automatically from compaction.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [strand](https://github.com/pedronaugusto/strand) reads and writes each record's
  line.
- [airlock](https://github.com/pedronaugusto/airlock) makes the files durable: every
  sync, atomic replace and backup batch, and the identity that tells two directories
  apart.
- [shakedown](https://github.com/pedronaugusto/shakedown) supplies the tests' doubles:
  faulted and counted `Io` calls and allocators, and airlock's syncs through
  `airlock.testing`, its test seam. Only the tests import them, so a project depending
  on chronicle never fetches them.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.

## Testing

`zig build test` runs the unit suite, writer-lock helper and examples in Debug by
default. Tests cover crash prefixes, checksum and chain failures, recovery, replay,
snapshots, retention, concurrency and allocation cleanup. `zig build examples` runs the
examples separately; `zig build check` compiles the suite, helper and examples without
running them. CI also runs `zig build docs -- usage --check`, and
`zig build check-consumer` builds a project that depends on chronicle with only strand
fetched.

[CI](.github/workflows/ci.yml) has three tiers. The fast tier runs the source checks and
the Debug suite with the examples on `ubuntu-latest`. The merge tier also runs the Debug
suite on `macos-latest` and `windows-latest`. The release tier runs Debug and ReleaseSafe
on all three hosts, ReleaseFast on Ubuntu, ReleaseSmall compile-only, every cross target
and ThreadSanitizer. The merge and release tiers also run the Debug suite on Ubuntu with
Zig master, a job that reports and never blocks.

`zig build bench` builds the benchmarks in [bench/](bench/) in ReleaseFast under
`zig-out/bench` and runs each, one after another, over every workload it has; each says
at its top how to run one workload alone. `zig build test` runs each once with
`--smoke`; CI times nothing.

The release tier's compile-only jobs cover `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`,
`x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.
CRC32C uses [warp](https://github.com/pedronaugusto/warp), which selects its hardware
kernel at run time, including in baseline builds. Additional Linux builds select
`x86_64_v2` and `cortex_a72` CPUs.

## Licence

MIT. See [LICENSE](LICENSE).
