#!/usr/bin/env bash
# Build the journal and counted-work benchmark harnesses against each named
# chronicle commit, into build/chronicle-bench-<commit> and work-bench-<commit>. The commit is exported with `git archive`
# (the chronicle repository is only read); build dirs live under build/.
# Snapshots must expose the strand module that their journal uses.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/.." && pwd)}"
for c in "$@"; do
  out="$build/chronicle-bench-$c"
  work="$build/work-bench-$c"
  [[ -x "$out" && -x "$work" ]] && continue
  src="$build/chron-src-$c"; bb="$build/chron-bb-$c"
  rm -rf "$src" "$bb"; mkdir -p "$src" "$bb/src"
  git -C "$repo" archive "$c" | tar -x -C "$src"
  cp "$here/build.zig" "$bb/"
  ln -s "$src" "$bb/chronicle-src"
  sed 's|.path = ".."|.path = "chronicle-src"|' "$here/build.zig.zon" > "$bb/build.zig.zon"
  cp -R "$here/src/." "$bb/src/"
  (cd "$bb" && ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global-cache}" "${ZIG:-zig}" build -j1 --prefix "$bb/out" --cache-dir "$bb/cache" -Doptimize=ReleaseFast)
  cp "$bb/out/bin/chronicle-bench" "$out"
  cp "$bb/out/bin/work-bench" "$work"
  rm -rf "$src" "$bb"
done
