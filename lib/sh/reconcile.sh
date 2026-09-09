#!/usr/bin/env bash
# reconcile.sh — the `if: always()` convergence step at the end of every advance job
# (spec §4.4, §16.1.3). It re-reads the state and finishes what advance.sh may have
# left half-done when it died between two writes:
#
#   status routing  ∧ dispatches[(KEY, RUN_ID)].status == finished → route.sh again
#   status queued   ∧ next.fired_at == null ∧ next.not_before ∈ {null, past} → fire.sh
#   status evidence ∧ evidence.pending.run_id == 0 → evidence.sh wait (re-query GitHub)
#
# Never raises: every problem is a log line and exit 0 (the fire path's own
# blocked:fire is fire.sh's, and a red job here would hide advance.sh's result).
#
# Environment: as advance.sh (ISSUE/D_ISSUE, KEY/D_KEY, RUN_ID, REPO, SWARM_STATE_KEY,
# CONFIG_JSON, RUN_DIR, WORKFLOW_REF, GH_TOKEN, FINALIZE).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${ISSUE:-${D_ISSUE:-}}
KEY=${KEY:-${D_KEY:-}}
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
RUN_DIR=${RUN_DIR:-.swarm-run}
LOGF="$RUN_DIR/advance.log"
log() { printf '%s\n' "$*" >&2; printf '%s reconcile: %s\n' "$(now)" "$*" >> "$LOGF" 2>/dev/null || true; }
[ -n "$ISSUE" ] || { log "no issue — nothing to reconcile"; exit 0; }
[ -n "${REPO:-}" ] && [ -n "${SWARM_STATE_KEY:-}" ] || { log "REPO or SWARM_STATE_KEY unset — nothing to reconcile"; exit 0; }
export ISSUE RUN_ID
if [ -z "${CONFIG_JSON:-}" ] || [ ! -f "$CONFIG_JSON" ]; then
  [ -f "$RUN_DIR/config.json" ] && CONFIG_JSON="$RUN_DIR/config.json"
fi
export CONFIG_JSON

STATE=$(tmpf .json) || { log "no temp dir"; exit 0; }
rc=0
"$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null || rc=$?
if [ $rc -ne 0 ]; then
  log "state #$ISSUE not readable (state.sh exit $rc) — nothing to reconcile"
  rm -f "$STATE"
  exit 0
fi
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
status=$(S '.status')
# a finalize run owns the record of current.run_id, not one under its own id
if [ "${FINALIZE:-false}" = true ] && [ -n "$KEY" ] && [ "$(S '.current.key')" = "$KEY" ] && [ -n "$(S '.current.run_id')" ]; then
  RUN_ID=$(S '.current.run_id')
  export RUN_ID
fi

case $status in
  routing)
    rec=$(jq -r --arg k "$KEY" --argjson r "$RUN_ID" '[(.dispatches // [])[] | select(.key == $k and .run_id == $r)] | last | .status // empty' "$STATE")
    if [ -n "$KEY" ] && [ "$rec" = finished ] && [ "$(S '.current.key')" = "$KEY" ]; then
      log "routing with a finished record ($KEY) — routing again"
      "$SWARM_LIB/route.sh" "$ISSUE" "$KEY" "$RUN_ID" || log "route.sh failed (exit $?)"
    else
      log "routing but the record ($KEY, $RUN_ID) is ${rec:-absent} — advance.sh owns this; nothing done"
    fi ;;
  queued)
    if [ -n "$(S '.next.key')" ] && [ -z "$(S '.next.fired_at')" ]; then
      nb=$(S '.next.not_before')
      if [ -z "$nb" ] || jq -en --arg nb "$nb" --arg now "$(now)" '($nb | fromdateiso8601) <= ($now | fromdateiso8601)' >/dev/null 2>&1; then
        log "queued and unfired ($(S '.next.key')) — firing"
        "$SWARM_LIB/fire.sh" "$ISSUE" "$(S '.next.stage')" "$(S '.next.role')" "$(S '.next.key')" chain >/dev/null || log "fire.sh failed (exit $?)"
      else
        log "queued with not_before $nb — the watchdog or /swarm resume fires it"
      fi
    else
      log "queued and already fired at $(S '.next.fired_at') — nothing to do"
    fi ;;
  evidence)
    if [ "$(S '.evidence.pending.run_id')" = 0 ] || [ -z "$(S '.evidence.pending.run_id')" ]; then
      slot=$(S '.evidence.pending.workflow')
      head=$(S '.evidence.pending.head')
      consumer=$(S '.evidence.pending.consumer')
      if [ -n "$slot" ] && [ -n "$head" ] && [ -n "$consumer" ]; then
        log "evidence pending without a run id — asking GitHub for $slot on ${head:0:7}"
        GITHUB_OUTPUT=/dev/null "$SWARM_LIB/evidence.sh" wait "$slot" "$head" "$consumer" >/dev/null 2>&1 || log "evidence.sh wait failed (exit $?)"
      fi
    else
      log "evidence pending run $(S '.evidence.pending.run_id') — waiting for its workflow_run event"
    fi ;;
  *) log "status $status — nothing to reconcile" ;;
esac
rm -f "$STATE"
exit 0
