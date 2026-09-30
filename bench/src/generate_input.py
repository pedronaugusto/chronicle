#!/usr/bin/env python3
"""Generate the one shared, fixed-width JSONL input used by every side."""

import os
import sys


RECORD_BYTES = 200
PREFIX = b'{"value":1,"padding":"'
SUFFIX = b'"}\n'
PADDING = b"x" * (RECORD_BYTES - len(PREFIX) - len(SUFFIX))
LINE = PREFIX + PADDING + SUFFIX


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_input.py OUTPUT COUNT")
    path = sys.argv[1]
    count = int(sys.argv[2])
    if count <= 0 or len(LINE) != RECORD_BYTES:
        raise SystemExit("invalid generator configuration")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    expected = count * RECORD_BYTES
    if os.path.exists(path) and os.path.getsize(path) == expected:
        return
    temporary = path + ".tmp"
    block = LINE * 10_000
    with open(temporary, "wb") as output:
        whole, tail = divmod(count, 10_000)
        for _ in range(whole):
            output.write(block)
        output.write(LINE * tail)
    os.replace(temporary, path)


if __name__ == "__main__":
    main()
