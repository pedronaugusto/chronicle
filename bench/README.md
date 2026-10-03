# Chronicle benchmarks

Run `./bench/quiet.sh` from the repository on an idle Mac. It builds immutable
library snapshots, then runs the complete journal, follow, raw-event and
counted-work pass. Harness files and history live on `bench`; merge current
main into this branch before a later pass. Snapshot builds use each revision's
pinned Strand dependency, so before/after reflects that dependency change too.

`./bench/quiet.sh --smoke` runs each job/side once with tiny fixtures and no
warm-up. Replays check sequence/count/value folds; follow jobs check their
cursor and count; counted-work checks seeks, subscriptions and reopened count;
every `cover-bench` job checks its checksums across sides.
OkayWAL smoke uses one worker and a small allocation instead of a 256 MiB
segment. Reports retain no timing, rate or ratio values. A successful smoke run
supports no performance claim.

`revisions.json` fixes A at `9792f666ea550879bb077fe2ba5aef697323525d` and B at
`621d5bbc42ff6e3572a1b4095e454251bb2f6614`, main when this pass was prepared. A
retains the original **2026-09-30 00:00:00 +01:00** cutoff. `--before REV --after REV`
selects other immutable snapshots; refresh the pins when main advances.

Every public operation has a job. The journal jobs: no-sync append, durable
single append, group commit, full replay, suffix replay, clean reopen, follow by
cursor/position/rearm, raw-event append and replay, sealed/active seeks, one/five
folds, append/replay cost, durable batch/single cost, and opening a
200,000-record log with the default tail (its historical 30-second ceiling kept
in full mode). The rest, from `cover-bench`: `checksum` (64 B, 1 KiB, 64 KiB),
`verify`, open with `verify = .full`, `replay` plus one `next` at 2,000
pseudo-random cursors, `seqAtOrAfter`, `subscribeFrom`/`subscribeAllFrom`,
`copySince`, `refresh` beside a writer, `waitPast` latency, `appendDeferred` made
durable by one append, `reconcile`, named readers (`tailer`, `commit`, `readers`,
`minCursor`, `Tailer.replay`), `snapshot`/`openWithSnapshot`, retention
(`dropSegmentsBefore`, `truncateAfter`, `compact`), `backup`, and `close`. Getters
(`lastSeq`, `oldestSeq`, `segmentCount`, `options`, `status`, `stats`), `nudge`,
`unsubscribe`, `segmentName`/`indexName` and the batch/replay accessors are pure
reads of held state and are not timed alone.

Comparisons, where the tool has the operation: Go tidwall/wal v1.2.1 (appends,
replays, reopen, read by index for `seek`, no-sync writes plus one `Sync` for
deferred appends, `TruncateFront` for `compact`, `TruncateBack` for
`truncateAfter`), Rust OkayWAL 0.3.1 (durable append, replays, reopen), plain Zig
files, CRC32C from Go's hash/crc32 (Castagnoli), the Rust crc32c 0.6.8 crate
(the one OkayWAL checks chunks with) and Zig's `std.hash.crc.Crc32Iscsi`, and for
`backup` a byte-for-byte copy of the segment and index files with the same
syncs. Each new job prints `checksum` rows (counts, sums, sequence numbers,
copied bytes) and the harness refuses a job whose sides disagree, in smoke and in
the timed pass. What has no equivalent is listed as unavailable in the report
with the reason; `copySince` is new since the before pin and runs on the after
side only.

Equivalence notes, for reading the ratios. OkayWAL's open recovers every entry
(reads it and checks its CRC); chronicle's default open reads the newest
segment and one line of each older one, so `clean_reopen` also carries
`before-verify-full`/`after-verify-full`, an open that reads and checks every
record. tidwall/wal reads only by index (`Read(i)`), stores no checksums, and its
replay sides decode each record with encoding/json; chronicle replays a segment
sequentially and checks every record's CRC. OkayWAL has no read from an entry id,
so its suffix replay recovers the whole log. tidwall's truncations fsync the
rewritten file and not the directory; chronicle's also sync the directory. Plain
files provide no journal integrity guarantee; strong plain-file sync and weaker
fsync are separate rows. Rust serde 1.0.229, serde_json 1.0.151, OkayWAL and
crc32c are pinned in Cargo.toml and Cargo.lock, Go pins in go.mod/go.sum.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Prepared scratch and compiler caches persist; tool caches remain
under `bench/build/quiet-cache`. Smoke builds both snapshot variants; the full pass reuses them. Full workloads
retain the existing million-record fixtures, 10,000 durable writes, and
tool-specific reopen/suffix repetitions; reported values normalize repetitions.

Quiet-only planning estimate: **20–45 minutes** after successful smoke preparation. See [QUIET-PREP.md](QUIET-PREP.md) for invocation counts, sizes and assumptions. This is a
planning estimate: the earlier range plus one diagnostic trial of each new job
on a shared machine (about 17 seconds across all sides), times six; it is not a
published figure. Have at least
10 GiB free for fixtures, separately prepared journals, scratch and caches.
`ZIG`, `GO`, `CARGO`, `PYTHON` and standard tool cache environment variables select
installed tools/caches. Specialized `run.sh`, `alternate.sh`, `per-commit.sh`
and `test-snapshot.sh` remain; `quiet.sh` is the complete pass entry point.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
