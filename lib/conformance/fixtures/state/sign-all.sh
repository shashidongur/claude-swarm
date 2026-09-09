#!/usr/bin/env bash
# sign-all.sh — regenerates the signed state bundles from the unsigned sources here:
#   fixtures/state/<variant>.json  →  fixtures/state-<variant>/state/issues-<N>.json
# signed with the harness key through `lib/sh/state.sh sign` (the same HMAC run.sh
# uses for a case's state.json), so a case can say "fixtures": ["state-running"] and
# be served a document whose signature verifies. Re-run after editing a source or the
# harness key. `month/` sources become the `state-month` bundle (several issues).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
export SWARM_STATE_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
n=0
for src in "$HERE"/*.json; do
  [ -f "$src" ] || continue
  v=$(basename "$src" .json)
  issue=$(jq -r '.issue' "$src")
  mkdir -p "$HERE/../state-$v/state"
  "$ROOT/lib/sh/state.sh" sign < "$src" > "$HERE/../state-$v/state/issues-$issue.json" || exit 1
  n=$((n + 1))
done
if [ -d "$HERE/month" ]; then
  mkdir -p "$HERE/../state-month/state"
  for src in "$HERE"/month/*.json; do
    [ -f "$src" ] || continue
    issue=$(jq -r '.issue' "$src")
    "$ROOT/lib/sh/state.sh" sign < "$src" > "$HERE/../state-month/state/issues-$issue.json" || exit 1
    n=$((n + 1))
  done
fi
echo "signed $n state fixture(s)"
