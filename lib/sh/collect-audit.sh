#!/usr/bin/env bash
# collect-audit.sh — the audit bundle a run job uploads (spec §11.4), `if: always()`
# after begin succeeded. Everything passes through redact.sh before it is written:
# the transcript is unmasked by the action and a role can `env` its way into it.
#
#   collect-audit.sh [--out DIR] [--critic-only]
#
# Writes to .swarm-run/audit/ (default):
#   prompt.txt                $RUNNER_TEMP/claude-prompts/claude-prompt.txt (the constant prompt)
#   brief.md, result.json, validation.json, critic.json, previous-attempt.md
#   execution.json.gz         $EXEC        (the role step's execution file; absence tolerated)
#   retry-execution.json.gz   $RETRY_EXEC
#   critic-execution.json.gz  $CRITIC_EXEC
#   evidence-index.json       .swarm-run/evidence/index.json
#   perimeter.txt             git status --porcelain, git diff --stat, the swarm tree's
#                             state (git -C .swarm status, or — the tree is an artifact
#                             download without .git — its writable files), HEAD and origin
# and, when a critic ran, also .swarm-run/critic/{critic.json, critic-execution.json.gz}
# so the handoff artifact carries the critic's output under one path for both classes.
# --critic-only (the separate critic job of a write-class role) writes only
# .swarm-run/critic/{critic.json, critic-execution.json.gz, perimeter.txt}.
#
# Environment: EXEC, RETRY_EXEC, CRITIC_EXEC (execution files), BRANCH; the secrets
# redact.sh reads (CLAUDE_CODE_OAUTH_TOKEN, ROLE_GH_TOKEN, RETRY_GH_TOKEN,
# CRITIC_GH_TOKEN) are never written anywhere. Never exits non-zero.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

RUN_DIR=".swarm-run"
OUT="$RUN_DIR/audit"
critic_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUT=$2; shift 2 ;;
    --critic-only) critic_only=1 ;;
    *) log "collect-audit: unknown option $1 (ignored)" ;;
  esac
  shift || true
done
[ $critic_only -eq 1 ] && OUT="$RUN_DIR/critic"

mkdir -p "$OUT" || { log "collect-audit: cannot create $OUT"; exit 0; }

copy_redacted() { # <src> <dest>
  [ -f "$1" ] || return 0
  redact < "$1" > "$2" 2>/dev/null || log "collect-audit: cannot write $2"
}
gzip_redacted() { # <src> <dest.gz>
  [ -n "$1" ] && [ -f "$1" ] || return 0
  redact < "$1" | gzip -9 > "$2" 2>/dev/null || log "collect-audit: cannot write $2"
}

perimeter() {
  {
    printf '# perimeter.txt — the workspace at the end of the job (%s)\n\n' "$(now)"
    printf '## HEAD\n%s\n' "$(git rev-parse HEAD 2>/dev/null || echo 'not a git checkout')"
    if [ -n "${BRANCH:-}" ]; then
      printf '## origin/%s\n%s\n' "$BRANCH" "$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo unknown)"
    fi
    printf '\n## git status --porcelain\n'
    git status --porcelain --untracked-files=all 2>/dev/null | grep -vE '^\?\? \.swarm(-run)?/' || true
    printf '\n## git diff --stat\n'
    git diff --stat 2>/dev/null || true
    printf '\n## git diff --stat --cached\n'
    git diff --stat --cached 2>/dev/null || true
    printf '\n## swarm tree (.swarm)\n'
    if [ -d .swarm ]; then
      if git -C .swarm rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -d .swarm/.git ]; then
        git -C .swarm status --porcelain 2>/dev/null || true
      else
        printf 'no git metadata (artifact download); writable files:\n'
        find .swarm -type f -perm -u+w 2>/dev/null | head -n 200
        printf 'newer than begin (mtime within the job):\n'
        find .swarm -type f -newer "$RUN_DIR/brief.md" 2>/dev/null | head -n 200
      fi
    else
      printf 'absent\n'
    fi
  } | redact
}

if [ $critic_only -eq 1 ]; then
  copy_redacted "$RUN_DIR/critic.json" "$OUT/critic.json"
  gzip_redacted "${CRITIC_EXEC:-}" "$OUT/critic-execution.json.gz"
  perimeter > "$OUT/perimeter.txt"
  log "collect-audit: critic bundle in $OUT ($(find "$OUT" -type f | wc -l) files)"
  exit 0
fi

prompt="${RUNNER_TEMP:-/tmp}/claude-prompts/claude-prompt.txt"
copy_redacted "$prompt" "$OUT/prompt.txt"
for f in brief.md result.json validation.json critic.json previous-attempt.md; do
  copy_redacted "$RUN_DIR/$f" "$OUT/$f"
done
copy_redacted "$RUN_DIR/evidence/index.json" "$OUT/evidence-index.json"
gzip_redacted "${EXEC:-}" "$OUT/execution.json.gz"
gzip_redacted "${RETRY_EXEC:-}" "$OUT/retry-execution.json.gz"
gzip_redacted "${CRITIC_EXEC:-}" "$OUT/critic-execution.json.gz"
perimeter > "$OUT/perimeter.txt"

if [ -f "$RUN_DIR/critic.json" ] || { [ -n "${CRITIC_EXEC:-}" ] && [ -f "$CRITIC_EXEC" ]; }; then
  mkdir -p "$RUN_DIR/critic"
  copy_redacted "$RUN_DIR/critic.json" "$RUN_DIR/critic/critic.json"
  gzip_redacted "${CRITIC_EXEC:-}" "$RUN_DIR/critic/critic-execution.json.gz"
fi

[ -n "${EXEC:-}" ] && [ -f "$EXEC" ] || log "collect-audit: no execution file for the role step (tolerated — the step died before writing one, or EXEC is unset)"
log "collect-audit: bundle in $OUT ($(find "$OUT" -type f | wc -l) files)"
exit 0
