#!/usr/bin/env bash
# refuse.sh — the `refuse` job (spec §5 G15, §16.1.1): a terminal refusal decided by
# resolve becomes visible on the issue. Idempotent per event: the `kind=refused`
# comment is keyed on the event id, so a re-run edits it instead of posting twice.
#
#   1. When a (verified) state exists: `state.sh write block --arg reason <BLOCK>`
#      (a precondition error — done/dropped — is logged, never fatal) and
#      `labels.sh project`; without a state the two labels are added directly.
#   2. The comment: `🧭 dispatch · 🚧 refused — <reason>` + marker
#      `kind=refused | issue | event=<id>`; edited when it already exists; its id is
#      recorded in `blocked.comment_id`.
#   3. The state comment is re-rendered.
#
# Environment: REPO, ISSUE, BLOCK (the blocked:* reason), REASON (text), EVENT_ID
# (defaults to run-<RUN_ID>), RUN_ID, SWARM_STATE_KEY, GH_TOKEN (contents + issues write).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

require_env REPO ISSUE BLOCK
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
export RUN_ID ISSUE
EVENT_ID=${EVENT_ID:-run-$RUN_ID}
REASON=${REASON:-refused}
detail=$(printf '%s' "$REASON" | redact | head -c 600)

snap=$(tmpf .json) || die "refuse: no temp dir"
have_state=0
rc=0
"$SWARM_LIB/state.sh" read "$ISSUE" > "$snap" 2>/dev/null 3>/dev/null || rc=$?
case $rc in
  0) have_state=1 ;;
  3) log "refuse: no state for #$ISSUE — labels are set directly" ;;
  6) log "refuse: state #$ISSUE has an invalid signature — not written; labels set directly" ;;
  *) log "refuse: state #$ISSUE unreadable (exit $rc) — labels set directly" ;;
esac

if [ $have_state -eq 1 ]; then
  rc=0
  "$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason "$BLOCK" --arg detail "$detail" > "$snap.new" 2>/dev/null || rc=$?
  case $rc in
    0) mv -f "$snap.new" "$snap" ;;
    5) log "refuse: state #$ISSUE moved on — block not recorded (status $(jq -r .status "$snap"))"; rm -f "$snap.new" ;;
    *) log "refuse: block not recorded (state.sh exit $rc)"; rm -f "$snap.new" ;;
  esac
fi

body=$(tmpf .md) || die "refuse: no temp dir"
"$SWARM_LIB/render.sh" refused "$body" --sarg reason "$detail" \
  --arg marker "$(marker refused "issue=$ISSUE" "event=$EVENT_ID")" || die "refuse: cannot render the comment"
cid=""
if existing=$(find_comment "$ISSUE" "$(marker_pred refused "event=$EVENT_ID")"); then
  cid=$(printf '%s' "$existing" | jq -r .id)
  edit_comment "$cid" "$body" || log "refuse: could not edit comment $cid"
  log "refuse: comment $cid for event $EVENT_ID edited"
else
  cid=$(post_comment "$ISSUE" "$body") || log "refuse: could not post the refused comment"
fi

if [ $have_state -eq 1 ]; then
  if [ -n "$cid" ] && jq -e '.status == "blocked"' "$snap" >/dev/null 2>&1; then
    "$SWARM_LIB/state.sh" write "$ISSUE" comment-id --arg target blocked --arg comment_id "$cid" > "$snap.new" 2>/dev/null \
      && mv -f "$snap.new" "$snap"
    rm -f "$snap.new"
  fi
  "$SWARM_LIB/labels.sh" project "$ISSUE" "$snap" >/dev/null || log "refuse: labels.sh project failed"
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "refuse: state comment not re-rendered"
else
  jq -n --arg b "blocked:$BLOCK" '{labels: ["swarm:blocked", $b]}' \
    | gh api -X POST "repos/$REPO/issues/$ISSUE/labels" --input - >/dev/null 2>&1 || log "refuse: could not add the labels"
fi
rm -f "$snap" "$body"
log "refuse: #$ISSUE blocked:$BLOCK — $detail"
exit 0
