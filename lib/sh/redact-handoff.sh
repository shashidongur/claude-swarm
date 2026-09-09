#!/usr/bin/env bash
# redact-handoff.sh — run redact.sh over the text files the role wrote, in place,
# before they leave the job.
#
#   redact-handoff.sh [<run dir>]        (default $RUN_DIR, else .swarm-run)
#
# Spec §11.4 says everything is redacted before it is uploaded, but only the audit
# bundle went through redact.sh: the handoff artifact and the artifacts that
# commit-artifacts.sh lands under docs/swarm/ did not. A role has Bash and its own
# OAuth token in the environment; guard-bash.sh does not stop `echo $VAR`, `set` or
# `declare -p`, so a token can end up in an artifact by accident or on purpose, and
# from there in a 3-day artifact any repository reader can download and in a commit on
# the branch. Redacting here closes both at once.
#
# Only known text extensions are touched, so nothing binary is corrupted. Three
# subdirectories are skipped: audit/ and evidence/ (collect-audit.sh already redacts
# what it writes there), and pending/ — a pending artifact's sha256 is recorded in the
# signed state when the role stages it, and begin.sh re-checks that hash before landing
# the file, so rewriting one here would fail the integrity check and stall the branch.
# Never fatal: a file that cannot be rewritten is left as it was and named in a warning.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

DIR=${1:-${RUN_DIR:-.swarm-run}}
[ -d "$DIR" ] || { log "redact-handoff: $DIR does not exist — nothing to redact"; exit 0; }

n=0
skipped=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  [ -L "$f" ] && { skipped=$((skipped + 1)); continue; }
  tmp="$f.redacting"
  if redact < "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if cmp -s "$f" "$tmp"; then rm -f "$tmp"; else mv -f "$tmp" "$f"; n=$((n + 1)); fi
  else
    rm -f "$tmp"
    skipped=$((skipped + 1))
    log "redact-handoff: could not rewrite $f — left as it was"
  fi
done < <(find "$DIR" -type f \
           \( -path "$DIR/audit" -o -path "$DIR/audit/*" -o -path "$DIR/evidence" -o -path "$DIR/evidence/*" \
              -o -path "$DIR/pending" -o -path "$DIR/pending/*" \) -prune -o \
           -type f \( -name '*.md' -o -name '*.json' -o -name '*.txt' -o -name '*.yaml' -o -name '*.yml' \
                      -o -name '*.patch' -o -name '*.diff' -o -name '*.csv' -o -name '*.log' \) -print 2>/dev/null)

log "redact-handoff: $n file(s) rewritten under $DIR${skipped:+, $skipped skipped}"
exit 0
