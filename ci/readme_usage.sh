#!/usr/bin/env bash
#
# zjournal — README.md's Usage snippet, extracted from examples/usage.zig.
#
# A code snippet in a README is a claim about how the library is used, and
# nothing compiles it. This one is a region of an example that `zig build
# examples` builds AND runs, so comparing this output against the document is
# what keeps the two the same thing.
#
# Usage: ci/readme_usage.sh          # writes the fenced block to stdout
#        ci/readme_usage.sh --check  # fails if README.md disagrees

set -uo pipefail
cd "$(dirname "$0")/.."

block=$(python3 - <<'PY'
import pathlib
import sys

source = pathlib.Path("examples/usage.zig")
text = source.read_text(encoding="utf-8")

MARKER = "// --- README:usage ---"
parts = text.split(MARKER)
if len(parts) != 3:
    sys.exit(
        "%s: expected exactly two %s markers, found %d"
        % (source, MARKER, len(parts) - 1)
    )

# The import is the one line a reader needs that cannot live inside main, so
# it is read from the file too rather than written out here.
imports = [
    line for line in text.splitlines() if line.startswith('const zjournal = @import(')
]
if len(imports) != 1:
    sys.exit("%s: expected exactly one `const zjournal = @import(...)` line" % source)

body = []
for line in parts[1].splitlines():
    # The region sits inside main; the README shows it at the left margin.
    body.append(line[4:] if line.startswith("    ") else line)

print("```zig")
print(imports[0])
print()
print("\n".join(body).strip("\n"))
print("```")
PY
) || exit 1

if [ "${1:-}" != "--check" ]; then
    printf '%s\n' "$block"
    exit 0
fi

# The document keeps the block between these markers; everything between them
# must be exactly what the example says.
current=$(python3 - <<'PY'
import pathlib
import sys

text = pathlib.Path("README.md").read_text(encoding="utf-8")
begin = "<!-- BEGIN GENERATED ci/readme_usage.sh -->"
end = "<!-- END GENERATED -->"
if begin not in text or end not in text:
    sys.exit("README.md: the generated-usage markers are missing")
sys.stdout.write(text.split(begin, 1)[1].split(end, 1)[0].strip("\n"))
PY
) || exit 1

if [ "$block" != "$current" ]; then
    echo "README.md's Usage block is not examples/usage.zig's region." >&2
    diff <(printf '%s\n' "$current") <(printf '%s\n' "$block") >&2
    exit 1
fi
echo "README.md's Usage block matches examples/usage.zig."
