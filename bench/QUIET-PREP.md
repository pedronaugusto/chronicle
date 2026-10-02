# Quiet preparation

Run `./bench/quiet.sh --smoke` before leaving the Mac idle. It builds both pinned snapshots, full and smoke artifacts, comparison tools and both corpus sizes, then runs the existing correctness smoke without benchmark clock samples. `./bench/quiet.sh --check-prepared` checks the full artifacts without building or running a timed workload. Normal `./bench/quiet.sh` requires a matching preparation receipt and reuses those artifacts; missing/stale preparation fails before measurements.

Snapshots and their compiler caches persist under `bench/build`; smoke and full Zig programs stay separate wherever smoke is a compile-time option. Installed comparison versions, source pins, full workload sizes, warm-ups, repetitions, comparison order and agreement checks are unchanged. Source identity and required artifact existence/sizes are checked without reading large corpus bytes into the page cache. Regenerate preparation after source/pin/tool changes or removal of build artifacts. Do not relocate the prepared worktree.

Per-sample reset/copy/mutation and checks remain where the original protocol needs a fresh starting state. Executable-internal fixture construction and measured watch setup remain part of the original invocation. Network fixture servers still start for the transport pass. These costs belong in the estimate, even when outside an individual timing interval.

Planning quiet duration: **15–40 minutes**, with all build/setup already completed, default repetitions, an idle Apple Silicon Mac and local SSD. This is an extrapolation, not a timing result or a deadline; there is no run time cap. It allows process startup, per-sample resets, reporting and correctness checks. Disk/fsync latency and compiler-backed graph analysis can exceed the range.

Smoke invocation inventory: **43**. Full inventory: **258 (43 × [one warm-up + five trials])**. Unavailable rows are not executable calls.

Journal input is 1,000,000 × 200 bytes. Six durable-write sides each do 10,000 writes per invocation: 360,000 durability operations including warm-ups. Retained suffix repetitions are 5/5/5/1/10; clean reopen repetitions are 200/200/100/1/20,000. Follow has 10,000 wakes per invocation, raw jobs have 200,000 records, and counted work retains its original 20,000/50,000/300/200,000 sizes. The expensive million-entry OkayWAL preparation is outside the quiet window.

Planning assumptions across packages: local process start roughly 0.5–3 ms, durable storage operations roughly 0.5–3 ms, JSON processing roughly 50–300 MB/s, file create/scan roughly 5,000–30,000 files/s, and graph adapters roughly 1–30 seconds per invocation depending on the workspace. These deliberately broad assumptions are not measurements of this Mac. Fixed gaps, 200 ms codec loops, idle durations and repetition counts provide independent floors. The combined budget is **56–140 minutes (about 1–2 hours 20 minutes)**; no historical timing samples or smoke wall duration are used.
