# chronicle

chronicle stores typed events in an append-only journal of JSON Lines segments. Sequence
numbers and chained CRC32C checksums let replay detect altered records and gaps before
folding them into state.

## Install

Requires Zig 0.16.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/chronicle`, then obtain the `chronicle` module
through `b.dependency` and add it to your executable's imports. Forward your target and
optimize settings.

## Usage

[examples/usage.zig](examples/usage.zig) defines `Ledger` as `chronicle.Journal(Event)`
and a `Balances` fold over account, deposit and withdrawal events. It opens the journal
at `path` with the supplied allocator and `std.Io`.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const chronicle = @import("chronicle");

var balances: Balances = .{};
var last: u64 = 0;
{
    const ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
    defer ledger.deinit(io);

    try ledger.subscribe(io, balances.sink());

    const now = std.Io.Clock.real.now(io).toMilliseconds();
    _ = try ledger.append(io, now, .{ .account_opened = .{ .id = 1, .owner = "ada" } });

    const follower = try ledger.replayAt(io, .after(0));
    defer follower.deinit(io);
    _ = (try follower.next(io)).?;

    last = try ledger.appendAll(io, &.{
        .{ .at = now, .event = .{ .deposited = .{ .id = 1, .cents = 5_000 } } },
        .{ .at = now, .event = .{ .withdrawn = .{ .id = 1, .cents = 1_250 } } },
    });
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
var from: u64 = 0;
if (opened.snapshot) |snapshot| {
    defer gpa.free(snapshot.state);
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
replays and tailers before the journal. `close` reports finalization errors; `deinit`
provides best-effort cleanup.

`append` takes the timestamp from the caller. With the default `sync = .always`, it
syncs the record before publishing it or returning its sequence number; `appendAll`
shares a record sync across a batch. A crash during a batch can leave a prefix, so a
batch is not a transaction. `appendDeferred` publishes before durability and requires a
later flush. The `.on_segment` policy syncs at sealing and close; `.never` leaves record
writeback to the operating system. Structural replacement flushes still apply under both
policies.

Durable writes use `fcntl(F_FULLFSYNC)` on macOS, `fsync` on Linux with `fdatasync` for
writes into reserved space, and `NtFlushBuffersFile` on Windows. The implementation
syncs directory changes on POSIX. Windows cannot provide that directory-sync guarantee,
so record flushing does not guarantee a new filename survives power loss.

Opening repairs an unfinished final line by default; `.on_truncated = .fail` refuses it.
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

- It does not provide transactions spanning multiple records or journals.
- It does not replicate a journal or coordinate writers across machines.
- It does not query event fields or build application indexes.
- It does not serialize the application's snapshot state for it.
- It does not choose retention policy or protect history automatically from compaction.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the unit suite, writer-lock helper and examples in Debug by
default. Tests cover crash prefixes, checksum and chain failures, recovery, replay,
snapshots, retention, concurrency and allocation cleanup. `zig build examples` runs the
examples separately; `zig build check` compiles the suite, helper and examples without
running them. CI also runs `ci/readme_usage.sh --check`.

[CI](.github/workflows/ci.yml) runs tests and examples in Debug and ReleaseSafe on
`ubuntu-latest`, `macos-latest` and `windows-latest`, plus ReleaseFast on Ubuntu.
ReleaseSmall is compile-only on Ubuntu. Separate Ubuntu jobs run ThreadSanitizer in
Debug and check formatting and cast reasons.

Compile-only jobs cover `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`,
`x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.
Additional Linux builds select `x86_64_v2` and `cortex_a72` CPUs to compile the checksum
instruction paths.

## Licence

MIT. See [LICENSE](LICENSE).
