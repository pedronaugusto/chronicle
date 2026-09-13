#!/usr/bin/env bash
#
# zjournal — the suite on Linux, from a machine that is not one.
#
# The promises this package makes are about files: an advisory lock, a rename,
# an `fsync` of a directory. Those are the parts of a filesystem that differ
# most between kernels, so "it passes here" is not the same claim as "it passes
# on the machine a daemon runs on". This builds the image in ci/linux.Dockerfile
# -- Debian plus the pinned Zig -- and runs the whole suite inside it, in Debug
# and in ReleaseSafe.
#
# The caches go under /tmp inside the container so that the repository's own
# .zig-cache, which holds objects for the host's architecture, is left alone.
#
# Usage: ci/linux.sh [extra zig build args...]

set -euo pipefail
cd "$(dirname "$0")/.."

image=${ZJOURNAL_LINUX_IMAGE:-zjournal-linux-zig-0.16.0}

if ! command -v docker >/dev/null 2>&1; then
    echo "ci/linux.sh needs docker on PATH." >&2
    exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> building $image"
    docker build -f ci/linux.Dockerfile -t "$image" ci
fi

for mode in Debug ReleaseSafe; do
    echo "==> zig build test -Doptimize=$mode (linux, in $image)"
    docker run --rm \
        -v "$PWD:/src" \
        -w /src \
        "$image" \
        zig build test \
        -Doptimize="$mode" \
        --cache-dir /tmp/zc \
        --global-cache-dir /tmp/zg \
        "$@"
done

echo "==> zig fmt --check (linux)"
docker run --rm -v "$PWD:/src" -w /src "$image" \
    zig fmt --check src examples build.zig

echo "all green on linux."
