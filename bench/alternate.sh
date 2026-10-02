#!/usr/bin/env bash
# Interleaved same-job samples: every trial runs each side once, in an order that
# rotates per trial, and waits for the 1-minute load average to fall under
# BENCH_MAX_LOAD (default 4) before each timed run. Best of BENCH_RUNS
# (default 7) per side and workload; raw rows and the load at each run are
# kept in build/alternate.raw.tsv.
#
#   ./alternate.sh [workload ...]   default: append_no_fsync replay_all replay_from_n clean_reopen
#
# Workloads: append_no_fsync append_fsync group_commit replay_all replay_from_n clean_reopen
#            follow_replay follow_resume (chronicle only)
#            raw_append raw_replay_all (chronicle only: a raw-event Journal(strand.Raw) over
#            a generated corpus (or BENCH_CORPUS) cycled to 200,000 records)
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"

# BENCH_NO_BUILD=1 measures the binaries already built; BENCH_CHRONICLE
# points the chronicle side at another build of chronicle-bench.
[[ "${BENCH_NO_BUILD:-0}" == 1 ]] || BENCH_BUILD_ONLY=1 ./run.sh >/dev/null

max_load=${BENCH_MAX_LOAD:-4}
trials=${BENCH_RUNS:-7}
count=1000000
fsync_count=10000
from=900000
input="$build/records-${count}.jsonl"
corpus="${BENCH_CORPUS:-$build/raw-events.jsonl}"
[[ -f "$corpus" ]] || "${PYTHON:-python3}" src/generate_input.py "$corpus" 571
raw_count=200000
[[ -f "$input" ]] || "${PYTHON:-python3}" src/generate_input.py "$input" "$count"

chronicle="${BENCH_CHRONICLE:-$build/zig-out/bin/chronicle-bench}"
plain="$build/zig-out/bin/plain-zig-bench"
tidwall="$build/tidwall-bench"
okaywal="$build/cargo-target/release/okaywal-bench"
run="$build/run"
mkdir -p "$run"

workloads=("$@")
if (( ${#workloads[@]} == 0 )); then
  workloads=(append_no_fsync replay_all replay_from_n clean_reopen)
fi

needs_data=0
for w in "${workloads[@]}"; do
  case "$w" in replay_all|replay_from_n|clean_reopen) needs_data=1 ;; esac
  case "$w" in raw_replay_all) "$chronicle" raw_prepare "$corpus" "$run/chronicle-raw-data" "$raw_count" ;; esac
done
if (( needs_data )); then
  if [[ "${BENCH_PREPARED:-0}" != 1 ]]; then
    "$chronicle" prepare "$input" "$run/chronicle-data" "$count"
  fi
  [[ -d "$run/tidwall-data" ]] || "$tidwall" prepare "$input" "$run/tidwall-data" "$count"
  [[ -d "$run/okaywal-data" ]] || "$okaywal" prepare "$input" "$run/okaywal-data" "$count"
  [[ -f "$run/plain-data.jsonl" ]] || "$plain" prepare "$input" "$run/plain-data.jsonl" "$count"
fi

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() {
  while awk -v l="$(load1)" -v m="$max_load" 'BEGIN{exit !(l>=m)}'; do sleep 20; done
}

# One command line per side for a workload, tab-separated "side<TAB>command".
# BENCH_BASE=<binary> adds a side "chronicle-base"; BENCH_VARIANTS="label=binary
# ..." adds one side "chronicle-<label>" per other build of chronicle-bench.
variants=${BENCH_VARIANTS:-}
if [[ -n "${BENCH_BASE:-}" ]]; then variants="base=$BENCH_BASE $variants"; fi
sides_for() {
  sides_one "$@"
  local v
  for v in $variants; do
    sides_one "$@" | awk -F'\t' -v c="$chronicle" -v b="${v#*=}" -v t="chronicle-${v%%=*}" \
      '$1 == "chronicle" { i = index($2, c); print t "\t" substr($2, 1, i - 1) b substr($2, i + length(c)) }'
  done
}
sides_one() {
  case "$1" in
    append_no_fsync)
      printf 'chronicle\t%s append_no_fsync %s %s %s\n' "$chronicle" "$input" "$run/chronicle-append" "$count"
      printf 'tidwall\t%s append_no_fsync %s %s %s\n' "$tidwall" "$input" "$run/tidwall-append" "$count"
      printf 'plain\t%s append_no_fsync %s %s %s\n' "$plain" "$input" "$run/plain-append.jsonl" "$count" ;;
    append_fsync)
      printf 'chronicle\t%s append_fsync %s %s %s\n' "$chronicle" "$input" "$run/chronicle-fsync" "$fsync_count"
      printf 'tidwall\t%s append_fsync %s %s %s\n' "$tidwall" "$input" "$run/tidwall-fsync" "$fsync_count"
      printf 'okaywal\t%s append_fsync %s %s %s\n' "$okaywal" "$input" "$run/okaywal-fsync" "$fsync_count"
      printf 'plain\t%s append_fsync %s %s %s\n' "$plain" "$input" "$run/plain-full-fsync.jsonl" "$fsync_count" ;;
    group_commit)
      printf 'chronicle\t%s group_commit %s %s %s\n' "$chronicle" "$input" "$run/chronicle-group" "$count"
      printf 'tidwall\t%s group_commit %s %s %s\n' "$tidwall" "$input" "$run/tidwall-group" "$count"
      printf 'plain\t%s group_commit %s %s %s\n' "$plain" "$input" "$run/plain-group.jsonl" "$count" ;;
    replay_all)
      printf 'chronicle\t%s replay_all %s %s %s\n' "$chronicle" "$input" "$run/chronicle-data" "$count"
      printf 'tidwall\t%s replay_all %s %s %s\n' "$tidwall" "$input" "$run/tidwall-data" "$count"
      printf 'okaywal\t%s replay_all %s %s %s\n' "$okaywal" "$input" "$run/okaywal-data" "$count"
      printf 'plain\t%s replay_all %s %s %s\n' "$plain" "$input" "$run/plain-data.jsonl" "$count" ;;
    replay_from_n)
      printf 'chronicle\t%s replay_from_n %s %s %s %s 5\n' "$chronicle" "$input" "$run/chronicle-data" "$count" "$from"
      printf 'tidwall\t%s replay_from_n %s %s %s %s 5\n' "$tidwall" "$input" "$run/tidwall-data" "$count" "$from"
      printf 'plain\t%s replay_from_n %s %s %s %s 10\n' "$plain" "$input" "$run/plain-data.jsonl" "$count" "$from" ;;
    clean_reopen)
      printf 'chronicle\t%s clean_reopen %s %s %s 200\n' "$chronicle" "$input" "$run/chronicle-data" "$count"
      printf 'tidwall\t%s clean_reopen %s %s %s 100\n' "$tidwall" "$input" "$run/tidwall-data" "$count"
      printf 'plain\t%s clean_reopen %s %s %s 20000\n' "$plain" "$input" "$run/plain-data.jsonl" "$count" ;;
    follow_replay|follow_resume|follow_rearm)
      printf 'chronicle\t%s %s %s %s %s 10000\n' "$chronicle" "$1" "$input" "$run/chronicle-follow" "$count" ;;
    raw_append)
      printf 'chronicle\t%s raw_append %s %s %s\n' "$chronicle" "$corpus" "$run/chronicle-raw-append" "$raw_count" ;;
    raw_replay_all)
      printf 'chronicle\t%s raw_replay_all %s %s %s\n' "$chronicle" "$corpus" "$run/chronicle-raw-data" "$raw_count" ;;
    *) echo "unknown workload $1" >&2; exit 2 ;;
  esac
}

raw="${BENCH_RAW:-$build/alternate.raw.tsv}"
: > "$raw"
echo "start $(date '+%F %T') load $(load1)" >&2
for w in "${workloads[@]}"; do
  lines=()
  while IFS= read -r l; do lines+=("$l"); done < <(
    sides_for "$w" | awk -F '\t' -v only="${BENCH_ONLY_CHRONICLE:-0}" 'only != 1 || $1 ~ /^chronicle/ { print }'
  )
  tags=()
  for l in "${lines[@]}"; do tags+=("${l%%$'\t'*}"); done
  n=${#lines[@]}
  # untimed warm-up of each side
  for l in "${lines[@]}"; do ${l#*$'\t'} >/dev/null; done
  for (( t = 0; t < trials; t++ )); do
    for (( k = 0; k < n; k++ )); do
      l=${lines[$(( (k + t) % n ))]}
      wait_quiet
      before=$(load1)
      tag=${l%%$'\t'*}
      ${l#*$'\t'} | awk -v b="$before" -v t="$tag" 'BEGIN{FS=OFS="\t"} {if (t ~ /^chronicle-/) $1 = t; print $0, b}' >> "$raw"
    done
  done
done
echo "end $(date '+%F %T') load $(load1)" >&2

awk 'BEGIN { FS=OFS="\t" }
  {
    key=$1 FS $2 FS $3 FS $5
    lower=($5 == "ms" || $5 == "us")
    if (!(key in best) || (lower ? $4 < best[key] : $4 > best[key])) best[key]=$4
    n[key]++
  }
  END { for (k in best) { split(k, f, FS); print f[2], f[1], f[3], best[k], f[4], n[k] } }' "$raw" |
  sort -t $'\t' -k1,1 -k2,2 | column -t -s $'\t'
