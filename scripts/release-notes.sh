#!/usr/bin/env bash
# Extracts the release notes for one version from CHANGELOG.md.
#
#   scripts/release-notes.sh v0.6.1            → notes on stdout
#   scripts/release-notes.sh 0.6.1 notes.md     → notes written to notes.md
#
# The notes are the "## [<version>] - <date>" section up to the next "## [" heading (heading
# included, link reference definitions excluded), followed by "**Full Changelog**: <url>" taken
# from the "[<version>]: <url>" reference at the bottom of CHANGELOG.md. Fails if the section is
# missing or empty.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <version|vVERSION> [output-file]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1#v}"
OUTPUT="${2:-}"

NOTES="$(python3 - "$ROOT/CHANGELOG.md" "$VERSION" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

heading = re.compile(r"^## \[" + re.escape(version) + r"\](\s|$)")
link_ref = re.compile(r"^\[[^\]]+\]:\s*\S")

start = next((i for i, line in enumerate(lines) if heading.match(line)), None)
if start is None:
    sys.exit(f"error: no '## [{version}]' section in {path}")

end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")), len(lines))
section = [line for line in lines[start:end] if not link_ref.match(line)]
while section and not section[-1].strip():
    section.pop()
if len(section) < 2 or not any(line.strip() for line in section[1:]):
    sys.exit(f"error: the '## [{version}]' section in {path} is empty")

ref = re.compile(r"^\[" + re.escape(version) + r"\]:\s*(\S+)")
url = next((m.group(1) for m in map(ref.match, lines) if m), None)
if url:
    section += ["", f"**Full Changelog**: {url}"]
else:
    print(f"warning: no '[{version}]: <url>' reference in {path}; omitting the compare link",
          file=sys.stderr)

print("\n".join(section))
PY
)"

if [[ -n "$OUTPUT" ]]; then
  printf '%s\n' "$NOTES" > "$OUTPUT"
else
  printf '%s\n' "$NOTES"
fi
