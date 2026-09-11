#!/usr/bin/env bash
# fire.sh — the baton, exactly (spec §3.5, D1): claim the fire in state, run the
# stub with `gh workflow run` under github.token, verify the run by the key at the
# end of its run-name, record the run id; a fire with no verified run is an error.
#
#   fire.sh <issue> <stage> <role> <key> <reason>
#
#   1. `state.sh write next-firing` — the CAS claim; a precondition error (exit 5)
#      means another writer already fired this key: log, exit 0 (nothing fired).
#   2. `gh workflow run <stub> --ref <default> -f issue -f stage -f role -f key -f reason`,
#      three tries, backing off 5/10/15 s.
#   3. Verify: `gh run list --workflow <stub> --event workflow_dispatch` filtered by
#      displayTitle ending in " <key>" and createdAt ≥ the fire time (60 s of clock skew
#      tolerated) — up to 12 × 5 s; nothing → one re-fire and another 60 s.
#   4. Found → `state.sh write next-fired` (a conditional no-op: the run may already
#      hold the claim), print the run id, exit 0.
#   5. Not found → `state.sh write block --arg reason fire` (next kept, fire fields
#      reset so /swarm resume re-fires), a `🧭 dispatch · 🚧 fire failed` comment keyed
#      on the key (edited when it already exists), labels when labels.sh is present,
#      the state comment re-rendered, exit 1 — the job is red.
#
# Environment: REPO, RUN_ID (or GITHUB_RUN_ID), SWARM_STATE_KEY, WORKFLOW_REF or
# STUB_FILE (the stub's file name), CONFIG_JSON (default branch, queued_refire_minutes),
# GH_TOKEN = github.token with actions: write. SWARM_FIRE_SLEEP overrides the 5 s
# poll interval (the harness sets 0). Prints the verified run id on stdout.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${1:-}
STAGE=${2:-}
ROLE=${3:-}
KEY=${4:-}
REASON=${5:-}
[ -n "$ISSUE" ] && [ -n "$STAGE" ] && [ -n "$ROLE" ] && [ -n "$KEY" ] && [ -n "$REASON" ] \
  || die "usage: fire.sh <issue> <stage> <role> <key> <reason>"
require_env REPO SWARM_STATE_KEY
export ISSUE
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
export RUN_ID
POLL=${SWARM_FIRE_SLEEP:-5}
POLLS=12

refire_minutes=30
if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then
  v=$(jq -r '.watchdog.queued_refire_minutes // empty' "$CONFIG_JSON" 2>/dev/null)
  [ -n "$v" ] && refire_minutes=$v
fi

# 1. the claim
rc=0
"$SWARM_LIB/state.sh" write "$ISSUE" next-firing --arg key "$KEY" --arg run_id "$RUN_ID" --arg refire_minutes "$refire_minutes" >/dev/null || rc=$?
case $rc in
  0) ;;
  5) log "fire of $KEY already claimed by another writer (or too recent) — nothing fired"; exit 0 ;;
  3) die "fire: no state for #$ISSUE" ;;
  6) die "fire: state #$ISSUE has an invalid signature — not firing (blocked:perimeter is the caller's)" ;;
  *) die "fire: cannot claim $KEY (state.sh exit $rc)" ;;
esac

STUB=$(stub_file) || die "fire: the stub file is unknown (WORKFLOW_REF or STUB_FILE)"
DEFAULT=$(default_branch) || die "fire: the default branch is unknown"
FIRED_AT=$(now)
# createdAt on GitHub's side may trail the runner's clock a little
SINCE=$(jq -rn --arg t "$FIRED_AT" '$t | fromdateiso8601 - 60 | todateiso8601')
ERR=$(tmpf .err) || die "fire: no temp dir"
: > "$ERR"

fire_once() {
  local try
  for try in 1 2 3; do
    if gh workflow run -R "$REPO" "$STUB" --ref "$DEFAULT" \
         -f issue="$ISSUE" -f stage="$STAGE" -f role="$ROLE" -f key="$KEY" -f reason="$REASON" >/dev/null 2>> "$ERR"; then
      return 0
    fi
    log "fire: gh workflow run failed (try $try): $(tail -n 1 "$ERR")"
    sleep $(( try * POLL ))
  done
  return 1
}

verify() {
  gh run list -R "$REPO" --workflow "$STUB" --event workflow_dispatch --json databaseId,displayTitle,createdAt --limit 20 \
    --jq "[.[] | select(.displayTitle | endswith(\" $KEY\")) | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | .[0].databaseId // empty" 2>/dev/null
}

wait_for_run() {
  local i rid=""
  for i in $(seq 1 $POLLS); do
    rid=$(verify)
    if [ -n "$rid" ]; then printf '%s\n' "$rid"; return 0; fi
    [ "$i" -lt $POLLS ] && sleep "$POLL"
  done
  return 1
}

fire_once || log "fire: three attempts of gh workflow run failed; looking for a run another writer may have created"
RID=$(wait_for_run) || RID=""
if [ -z "$RID" ]; then
  log "fire: no run for $KEY within $((POLLS * POLL)) s; re-firing once"
  fire_once || log "fire: the re-fire failed too"
  RID=$(wait_for_run) || RID=""
fi

if [ -n "$RID" ]; then
  "$SWARM_LIB/state.sh" write "$ISSUE" next-fired --arg key "$KEY" --arg run_id "$RID" >/dev/null \
    || log "fire: next-fired did not record run $RID (state.sh exit $?)"
  log "fire: $KEY verified as run $RID"
  rm -f "$ERR"
  printf '%s\n' "$RID"
  exit 0
fi

# 5. a fire with no verified run is an error, never a log line
detail=$(tail -c 600 "$ERR" | redact | tr '\n' ' ')
[ -n "$detail" ] || detail="no run named with $KEY appeared within $((2 * POLLS * POLL)) s"
"$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason fire --arg detail "$detail" >/dev/null \
  || log "fire: could not record blocked:fire (state.sh exit $?)"

body=$(tmpf .md) || die "fire: no temp dir"
"$SWARM_LIB/render.sh" fire-failed "$body" --sarg error "$detail" --arg key "$KEY" \
  --arg marker "$(marker died "issue=$ISSUE" "key=$KEY" "stage=$STAGE" "role=$ROLE")" \
  || die "fire: cannot render the fire-failed comment"
if existing=$(find_comment "$ISSUE" "$(marker_pred died "key=$KEY")"); then
  cid=$(printf '%s' "$existing" | jq -r .id)
  edit_comment "$cid" "$body" || log "fire: could not edit comment $cid"
else
  cid=$(post_comment "$ISSUE" "$body") || log "fire: could not post the fire-failed comment"
fi
[ -n "${cid:-}" ] && "$SWARM_LIB/state.sh" write "$ISSUE" comment-id --arg target blocked --arg comment_id "$cid" >/dev/null 2>&1
if [ -x "$SWARM_LIB/labels.sh" ]; then
  snap=$(tmpf .json) || die "fire: no temp dir"
  if "$SWARM_LIB/state.sh" read "$ISSUE" > "$snap" 2>/dev/null; then
    "$SWARM_LIB/labels.sh" project "$ISSUE" "$snap" || log "fire: labels.sh project failed"
  fi
  rm -f "$snap"
fi
"$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "fire: state comment not re-rendered"
rm -f "$ERR" "$body"
die "fire: no verified run for $KEY after a re-fire — blocked:fire; /swarm resume re-fires it"
