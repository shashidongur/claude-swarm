#!/usr/bin/env bash
# exec-stats.sh — an action execution file → the stats advance records (spec §11.5).
#
#   exec-stats.sh <execution.json[.gz]>        → one JSON object on stdout, exit 0 always
#
# The file may be a JSON array of messages (the action's execution file), JSONL (one
# message per line), or gzipped either way (the audit bundle stores it gzipped). An
# absent, empty or unparsable file — a killed run leaves a truncated one (§17 R5) —
# answers `{present: false, reason: …}`; a JSONL file with a broken last line keeps the
# lines that parse. The fields are lib/jq/exec-stats.jq's; the whole result is passed
# through redact so `last_text` and `bash_commands` never carry a token into state.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

absent() {
  printf '{"present":false,"reason":"%s"}\n' "$1"
  exit 0
}

f=${1:-}
[ -n "$f" ] || die "usage: exec-stats.sh <execution.json[.gz]>"
[ -f "$f" ] || absent "absent"
[ -s "$f" ] || absent "empty"

src=$(tmpf .exec) || die "exec-stats: cannot create a temporary file"
lines=$(tmpf .lines) || die "exec-stats: cannot create a temporary file"
trap 'rm -f "$src" "$lines"' EXIT

if gzip -t "$f" >/dev/null 2>&1 || [ "${f%.gz}" != "$f" ]; then
  # a truncated gzip stream still yields what it had before the cut
  gzip -dc "$f" > "$src" 2>/dev/null || true
else
  cp "$f" "$src"
fi
[ -s "$src" ] || absent "empty"

if ! jq -c 'if type == "array" then .[] else . end' "$src" > "$lines" 2>/dev/null; then
  jq -cR 'fromjson? // empty' "$src" > "$lines" 2>/dev/null || true
fi
[ -s "$lines" ] || absent "unparsable"

jq -s -f "$SWARM_ROOT/lib/jq/exec-stats.jq" "$lines" | redact
exit 0
