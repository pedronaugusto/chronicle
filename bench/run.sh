#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
results="${BENCH_RESULTS:-$build/results.tsv}"

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global-cache}"
export CARGO_HOME="${CARGO_HOME:-$build/cargo-home}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build/cargo-target}"
export GOPATH="${GOPATH:-$build/go-path}"
export GOCACHE="${GOCACHE:-$build/go-cache}"
export GOMODCACHE="${GOMODCACHE:-$build/go-mod-cache}"

"${ZIG:-zig}" build -j1 --prefix "$build/zig-out" --cache-dir "$build/zig-cache" -Doptimize=ReleaseFast
"${CARGO:-cargo}" build -j1 --release --locked
"${GO:-go}" build -p=1 -mod=readonly -ldflags='-s -w' -o "$build/tidwall-bench" ./src/tidwall_bench.go
if [[ "${BENCH_BUILD_ONLY:-0}" == 1 ]]; then
  exit 0
fi

if [[ "${BENCH_SMOKE:-0}" == 1 ]]; then
  count=1
  fsync_count=1
  from=1
  chronicle_from_reps=1
  tidwall_from_reps=1
  okaywal_from_reps=1
  plain_from_reps=1
  chronicle_reopen_reps=1
  tidwall_reopen_reps=1
  okaywal_reopen_reps=1
  plain_reopen_reps=1
else
  count=1000000
  fsync_count=10000
  from=900000
  chronicle_from_reps=5
  tidwall_from_reps=5
  okaywal_from_reps=1
  plain_from_reps=10
  chronicle_reopen_reps=200
  tidwall_reopen_reps=100
  okaywal_reopen_reps=1
  plain_reopen_reps=20000
fi

trials=${BENCH_RUNS:-5}
[[ "${BENCH_SMOKE:-0}" != 1 ]] || trials=1
if ! [[ "$trials" =~ ^[1-9][0-9]*$ ]]; then
  echo "BENCH_RUNS must be a positive integer" >&2
  exit 2
fi

input="$build/records-${count}.jsonl"
"${PYTHON:-python3}" src/generate_input.py "$input" "$count"

chronicle="$build/zig-out/bin/chronicle-bench"
plain="$build/zig-out/bin/plain-zig-bench"
tidwall="$build/tidwall-bench"
okaywal="$CARGO_TARGET_DIR/release/okaywal-bench"

"$chronicle" prepare "$input" "$build/run/chronicle-data" "$count"
"$tidwall" prepare "$input" "$build/run/tidwall-data" "$count"
"$okaywal" prepare "$input" "$build/run/okaywal-data" "$count"
"$plain" prepare "$input" "$build/run/plain-data.jsonl" "$count"

raw=$(mktemp "$build/results.raw.XXXXXX")
best=$(mktemp "$build/results.best.XXXXXX")
trap 'rm -f "$raw" "$best"' EXIT

bench() {
  [[ "${BENCH_SMOKE:-0}" == 1 ]] || "$@" >/dev/null
  local trial=0
  local output
  while (( trial < trials )); do
    output=$("$@")
    printf '%s\n' "$output" >> "$raw"
    ((trial += 1))
  done
}

bench "$chronicle" append_no_fsync "$input" "$build/run/chronicle-append" "$count"
bench "$tidwall" append_no_fsync "$input" "$build/run/tidwall-append" "$count"
bench "$plain" append_no_fsync "$input" "$build/run/plain-append.jsonl" "$count"

bench "$chronicle" append_fsync "$input" "$build/run/chronicle-fsync" "$fsync_count"
bench "$tidwall" append_fsync "$input" "$build/run/tidwall-fsync" "$fsync_count"
bench "$okaywal" append_fsync "$input" "$build/run/okaywal-fsync" "$fsync_count"
bench "$plain" append_fsync "$input" "$build/run/plain-full-fsync.jsonl" "$fsync_count"
bench "$plain" append_fsync_weak "$input" "$build/run/plain-fsync.jsonl" "$fsync_count"

bench "$chronicle" group_commit "$input" "$build/run/chronicle-group" "$count"
bench "$tidwall" group_commit "$input" "$build/run/tidwall-group" "$count"
bench "$plain" group_commit "$input" "$build/run/plain-group.jsonl" "$count"

bench "$chronicle" replay_all "$input" "$build/run/chronicle-data" "$count"
bench "$tidwall" replay_all "$input" "$build/run/tidwall-data" "$count"
bench "$okaywal" replay_all "$input" "$build/run/okaywal-data" "$count"
bench "$plain" replay_all "$input" "$build/run/plain-data.jsonl" "$count"

bench "$chronicle" replay_from_n "$input" "$build/run/chronicle-data" "$count" "$from" "$chronicle_from_reps"
bench "$tidwall" replay_from_n "$input" "$build/run/tidwall-data" "$count" "$from" "$tidwall_from_reps"
bench "$okaywal" replay_from_n "$input" "$build/run/okaywal-data" "$count" "$from" "$okaywal_from_reps"
bench "$plain" replay_from_n "$input" "$build/run/plain-data.jsonl" "$count" "$from" "$plain_from_reps"

bench "$chronicle" clean_reopen "$input" "$build/run/chronicle-data" "$count" "$chronicle_reopen_reps"
bench "$tidwall" clean_reopen "$input" "$build/run/tidwall-data" "$count" "$tidwall_reopen_reps"
bench "$okaywal" clean_reopen "$input" "$build/run/okaywal-data" "$count" "$okaywal_reopen_reps"
bench "$plain" clean_reopen "$input" "$build/run/plain-data.jsonl" "$count" "$plain_reopen_reps"

na_output=$("$okaywal" append_no_fsync "$input" "$build/run/okaywal-na" "$count")
printf '%s\n' "$na_output" >> "$raw"
na_output=$("$okaywal" group_commit "$input" "$build/run/okaywal-na" "$count")
printf '%s\n' "$na_output" >> "$raw"

awk 'BEGIN { FS=OFS="\t" }
  $4 == "n/a" { na[$1 FS $2 FS $3 FS $5]=1; next }
  {
    key=$1 FS $2 FS $3 FS $5
    lower=($5 == "ms")
    if (!(key in value) || (lower ? $4 < value[key] : $4 > value[key])) value[key]=$4
  }
  END {
    for (key in value) print key, value[key]
    for (key in na) print key, "n/a"
  }' "$raw" | awk 'BEGIN { FS=OFS="\t" } { print $1,$2,$3,$5,$4 }' | sort -t $'\t' -k2,2 -k1,1 > "$best"

{
  printf 'side\tworkload\tmetric\tvalue\tunit\n'
  cat "$best"
} > "$results"

if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$results"
else
  cat "$results"
fi
