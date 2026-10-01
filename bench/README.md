# chronicle benchmarks

Compares append, sync, group commit, replay, suffix replay and reopen with
Go tidwall/wal, Rust OkayWAL and plain Zig files. OkayWAL lacks no-sync and
explicit batching APIs; plain files lack journal integrity guarantees.
`alternate.sh` also exposes Chronicle follow and raw-event workloads.

From `bench/`, run `./run.sh` on a quiet machine: one warm-up, five trials
(`BENCH_RUNS`). `BENCH_SMOKE=1 ./run.sh` uses one record/sync/iteration,
without warm-up; `BENCH_BUILD_ONLY=1` builds only. The package is this
repository at `..`; its pinned strand dependency supplies the journal Raw type.

Go tidwall/wal v1.2.1 is pinned in `go.mod`/`go.sum`. OkayWAL 0.3.1,
serde 1.0.229 and serde_json 1.0.151 are exact in `Cargo.toml`/`Cargo.lock`.
Standard libraries and sync behavior depend on installed toolchains; record
their versions. `BENCH_BUILD_DIR`/`BENCH_RESULTS` select generated output,
defaulting to `build/`; `ZIG`, `GO`, `CARGO`, `PYTHON` select tools.
Snapshot scripts take commits and `BENCH_REPO` (this repository by default).
Raw inputs default to generated data or `BENCH_CORPUS`. Generated files are ignored.


`zig build -Doptimize=ReleaseFast` also builds `work-bench`. Run
`zig-out/bin/work-bench build/new-scratch` with a directory that does not
exist, beneath this checkout. It measures the claims formerly in the
unit suite: active against sealed seeks, five shared folds against one,
append and replay time per record, and group commit against single durable
appends, and opening 200,000 records with the default tail. The large-open
workload retains the former 30,000 ms ceiling; the others print measurements
and ratios without speed thresholds. The
scratch directory is owned and removed by that invocation. `-Dsmoke=true`
uses tiny fixtures to check the harness; smoke timings are not measurements. The cancellation tests retained on this
branch also keep their five-second progress watchdogs; the release unit suite
checks cancellation without those wall-clock progress ceilings.

`./per-commit.sh <commit>` also retains `build/work-bench-<commit>`, so these
measurements can run against the library commit being reviewed. Snapshot
builds copy the harness source directory as one unit. Prefer full commit
identifiers: the resulting executables are cached under the supplied name.

`./test-snapshot.sh <commit>` checks both snapshot executables and rebuilding
when only the older journal executable is cached. Its scratch and dependency
cache stay in a temporary directory under `bench/build` and are removed.
