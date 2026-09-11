#!/usr/bin/env bash
# advance-failed.sh — G36 (spec §4.5, §5.3): the `if: failure()` step of the advance
# job. A red Actions run must also be a red issue, without losing the completed run:
#
#   precondition  current.run_id == RUN_ID ∧ status ∈ {running, routing}
#                 (anything else — the record was finalised and routing happened, or
#                 another dispatch owns the issue — is a log line, exit 0)
#   effect        state.sh write block --arg reason stalled (current untouched, so a
#                 GitHub re-run of the advance job or `/swarm resume` → finalize can
#                 still finish the record from the stored handoff), the comment
#                 `💀 advance · failed — <run url>; "Re-run failed jobs" or /swarm resume`
#                 (edited when it already exists), labels.sh project, the state comment.
#
# Exit 0 always (the job is already red). Environment: ISSUE/D_ISSUE, KEY/D_KEY,
# RUN_ID, REPO, SWARM_STATE_KEY, GH_TOKEN, CONFIG_JSON (optional), RUN_DIR, FINALIZE.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${ISSUE:-${D_ISSUE:-}}
KEY=${KEY:-${D_KEY:-}}
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
RUN_DIR=${RUN_DIR:-.swarm-run}
LOGF="$RUN_DIR/advance.log"
log() { printf '%s\n' "$*" >&2; printf '%s advance-failed: %s\n' "$(now)" "$*" >> "$LOGF" 2>/dev/null || true; }
[ -n "$ISSUE" ] || { log "no issue"; exit 0; }
[ -n "${REPO:-}" ] && [ -n "${SWARM_STATE_KEY:-}" ] || { log "REPO or SWARM_STATE_KEY unset"; exit 0; }
export ISSUE RUN_ID
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
if [ -z "${CONFIG_JSON:-}" ] || [ ! -f "$CONFIG_JSON" ]; then [ -f "$RUN_DIR/config.json" ] && CONFIG_JSON="$RUN_DIR/config.json"; fi
export CONFIG_JSON

STATE=$(tmpf .json) || { log "no temp dir"; exit 0; }
rc=0
"$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null || rc=$?
[ $rc -eq 0 ] || { log "state #$ISSUE not readable (exit $rc) — the failure stays in the Actions log"; rm -f "$STATE"; exit 0; }
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
status=$(S '.status')
cur_run=$(S '.current.run_id')
cur_key=$(S '.current.key')
[ -n "$KEY" ] || KEY=$cur_key
# a finalize run finalises the record of current.run_id; the failure is still this dispatch's
if [ "${FINALIZE:-false}" = true ] && [ "$cur_key" = "$KEY" ] && [ -n "$cur_run" ]; then RUN_ID=$cur_run; export RUN_ID; fi

if [ "$cur_run" != "$RUN_ID" ]; then
  log "current.run_id is ${cur_run:--}, not $RUN_ID — this run does not own the dispatch; nothing recorded"
  rm -f "$STATE"
  exit 0
fi
case $status in
  running|routing) ;;
  *) log "status is $status — the record was finalised and routed (or blocked) before the failure; nothing recorded"; rm -f "$STATE"; exit 0 ;;
esac

"$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason stalled --arg detail "advance failed in run $RUN_ID; current untouched" --arg from_key "$cur_key" >/dev/null 2>&1 \
  && log "blocked:stalled recorded (current untouched)" || log "block stalled not recorded (state.sh exit $?)"

body=$(tmpf .md) || { rm -f "$STATE"; exit 0; }
"$SWARM_LIB/render.sh" advance-failed "$body" --arg run_url "$RUN_URL" \
  --arg marker "$(marker died "key=$KEY" "run=$RUN_ID" "topic=advance")" || { log "cannot render the comment"; rm -f "$body" "$STATE"; exit 0; }
if existing=$(find_comment "$ISSUE" "$(marker_pred died "key=$KEY" "topic=advance")"); then
  cid=$(printf '%s' "$existing" | jq -r .id)
  edit_comment "$cid" "$body" || log "could not edit comment $cid"
else
  cid=$(post_comment "$ISSUE" "$body") || log "could not post the comment"
fi
[ -n "${cid:-}" ] && "$SWARM_LIB/state.sh" write "$ISSUE" comment-id --arg target blocked --arg comment_id "$cid" >/dev/null 2>&1
rm -f "$body"
if "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null; then
  [ -x "$SWARM_LIB/labels.sh" ] && { "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" || log "labels.sh project failed"; }
fi
"$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "state comment not re-rendered"
rm -f "$STATE"
exit 0
