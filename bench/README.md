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
