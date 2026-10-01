#!/usr/bin/env bash
# Build both harnesses against an immutable library snapshot, and prove that
# an older cached journal executable alone cannot hide a missing work harness.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
commit="$(git -C "$here/.." rev-parse "${1:-HEAD}^{commit}")"
mkdir -p "$here/build"
scratch="$(mktemp -d "$here/build/snapshot-test.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export BENCH_BUILD_DIR="$scratch"
export ZIG_GLOBAL_CACHE_DIR="$scratch/zig-global-cache"
"$here/per-commit.sh" "$commit"
test -x "$scratch/chronicle-bench-$commit"
test -x "$scratch/work-bench-$commit"
rm "$scratch/work-bench-$commit"
"$here/per-commit.sh" "$commit"
test -x "$scratch/chronicle-bench-$commit"
test -x "$scratch/work-bench-$commit"
