# Chronicle benchmarks

Run `./bench/quiet.sh` from the repository on an idle Mac. It builds immutable
library snapshots, then runs the complete journal, follow, raw-event and
counted-work pass. Harness files and history live on `bench`; merge current
main into this branch before a later pass. Snapshot builds use each revision's
pinned Strand dependency, so before/after reflects that dependency change too.

`./bench/quiet.sh --smoke` runs each job/side once with tiny fixtures and no
warm-up. Replays check sequence/count/value folds; follow jobs check their
cursor and count; counted-work checks seeks, subscriptions and reopened count.
OkayWAL smoke uses one worker and a small allocation instead of a 256 MiB
segment. Reports retain no timing, rate or ratio values. A successful smoke run
supports no performance claim.

By default A is the last first-parent main commit before **2026-09-30 00:00:00
+0100**, and B is current local main. The explicit time and offset enforce the
midnight boundary (Git's date-only `--before=2026-09-30` can inherit the current
time of day). `--before REV --after REV` selects other immutable snapshots.
Each job runs A, B, then its existing same-job tools, repeating that order five
times (`BENCH_RUNS`). One warm-up per side precedes those trials; all raw samples
are retained and summaries use medians. Inputs are generated once and each side
owns separate journal data and scratch. The final API returns opaque journal
and replay owners: `src/compat.zig` borrows the old value or new owner pointer.
This changes ownership spelling, with the same append/replay/subscription calls
and payloads. Segment count handles the older infallible observation.

The jobs are no-sync append, durable single append, group commit, full replay,
suffix replay, clean reopen, follow by cursor/position/rearm, raw-event append
and replay, sealed/active seeks, one/five folds, append/replay cost, durable
batch/single cost, and opening a 200,000-record log with the default tail. The
large-open job retains its historical 30-second ceiling in full mode; a failure
leaves a failed report with the samples already collected. Smoke checks count
but skips that speed ceiling.

The existing comparisons remain Go tidwall/wal v1.2.1, Rust OkayWAL 0.3.1 and
plain Zig files. OkayWAL has no no-sync or explicit batching API: those rows
remain unavailable. Plain files provide no journal integrity guarantee. Strong
plain-file sync and weaker fsync are separate rows; cross-tool sync semantics
are not interchangeable. Follow/raw/counted-work have only A/B sides. serde
1.0.229 and serde_json 1.0.151 are pinned alongside OkayWAL in Cargo.toml and
Cargo.lock. Go pins are in go.mod/go.sum. No comparison tool is added.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Scratch is removed on success or failure; tool caches remain
under `bench/build/quiet-cache`. Each pass builds fresh binaries. Full workloads
retain the existing million-record fixtures, 10,000 durable writes, and
tool-specific reopen/suffix repetitions; reported values normalize repetitions.

Allow roughly **30–60 minutes** for the default full pass on an Apple Silicon
Mac with cached dependencies, plus first-time downloads/builds. This is a
planning estimate, not a measurement from this preparation. Have at least
10 GiB free for fixtures, separately prepared journals, scratch and caches.
`ZIG`, `GO`, `CARGO`, `PYTHON` and standard tool cache environment variables select
installed tools/caches. Specialized `run.sh`, `alternate.sh`, `per-commit.sh`
and `test-snapshot.sh` remain; `quiet.sh` is the complete pass entry point.
