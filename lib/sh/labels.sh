#!/usr/bin/env bash
# labels.sh — labels are a projection of state (spec §4.3, §15.1).
#
#   labels.sh install <owner/repo> [--config <config.json>]
#       Creates (or refreshes with --force) every label v2 writes: stage, gate,
#       waiting, parked/dropped/short/lane, the blocked:* reasons, the type/size/prio
#       labels and one area:<lane> per configured lane (+ area:both). Suffixes
#       "(v1, unused by v2)" to the v1 labels v2 never writes. Idempotent.
#   labels.sh project <issue> <state.json>
#       Computes the desired set from the state document, reads the issue's current
#       labels and adds the missing / removes the stale ones — only inside the managed
#       namespaces `swarm:` (minus the human-owned set), `blocked:`, `size:`, `area:`,
#       `prio:` and the three type labels. Human-owned, never removed here:
#       swarm:hands-off, swarm:control, swarm:halt, swarm:halt-pipeline; swarm:ready is
#       consumed by `start` and never touched by the projection. Prints "+label" /
#       "-label" lines; exit 0 even when nothing changed.
#   labels.sh desired <state.json>
#       Prints the desired set, one label per line (what `project` would converge to).
#   labels.sh reconcile <owner/repo>
#       One idempotent pass over closed issues carrying `swarm:pr` (v1): when a merged
#       pull request references the issue (timeline cross-references), swarm:pr is
#       removed and swarm:done added.
#
# Environment: REPO (or the <owner/repo> argument), GH_TOKEN with issues: write,
# CONFIG_JSON (lane names for `install`).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

HUMAN_OWNED="swarm:hands-off swarm:control swarm:halt swarm:halt-pipeline swarm:ready"
TYPE_LABELS="bug feature chore"

is_human_owned() {
  local l=$1 h
  for h in $HUMAN_OWNED; do [ "$h" = "$l" ] && return 0; done
  return 1
}

# managed <label>: inside a namespace the projection owns (and not human-owned)
is_managed() {
  local l=$1 t
  is_human_owned "$l" && return 1
  case $l in
    swarm:*|blocked:*|size:*|area:*|prio:*) return 0 ;;
  esac
  for t in $TYPE_LABELS; do [ "$t" = "$l" ] && return 0; done
  return 1
}

# ── install ─────────────────────────────────────────────────────────────────────

create() { # <name> <color> [<description>]
  local name=$1 color=$2 desc=${3:-}
  if [ -n "$desc" ]; then
    gh label create -R "$REPO" "$name" -c "$color" -d "$desc" --force >/dev/null 2>&1 \
      || log "labels: could not create $name"
  else
    gh label create -R "$REPO" "$name" -c "$color" --force >/dev/null 2>&1 \
      || log "labels: could not create $name"
  fi
}

cmd_install() {
  local r=${1:-${REPO:-}} cfg=${CONFIG_JSON:-} lanes lane
  [ -n "$r" ] || die "install: <owner/repo>"
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --config) cfg=$2; shift 2 ;;
      *) die "install: unknown option $1" ;;
    esac
  done
  REPO=$r
  export REPO
  create swarm:ready             0E8A16 "start the swarm on this issue (approvers only)"
  create swarm:triage            1D76DB "stage 1: triage classifying the issue"
  create swarm:requirements      1D76DB "stage 2: analyst writing user stories and acceptance criteria"
  create swarm:design            1D76DB "stage 3: design and accessibility review"
  create swarm:architecture      1D76DB "stage 4: ADR, API contract, migration, flags, rollback, threat model"
  create swarm:build             1D76DB "stage 5: tests, implementation and review per lane"
  create swarm:test              1D76DB "stage 6: evidence and QA"
  create swarm:security          1D76DB "stage 7: scans and compliance review"
  create swarm:release           1D76DB "stage 8: PR assembled, awaiting merge by an approver"
  create swarm:retro             1D76DB "stage 9: post-mortem and memory"
  create swarm:gate:requirements FBCA04 "waiting: /swarm approve or /swarm reject <why>"
  create swarm:gate:architecture FBCA04 "waiting: /swarm approve or /swarm reject <why>"
  create swarm:gate:release      FBCA04 "waiting: an approver merges the PR"
  create swarm:gate:question     FBCA04 "waiting: the reporter's answer resumes the analyst"
  create swarm:gate:confidence   FBCA04 "waiting: critic escalated; /swarm approve or /swarm redo <stage>"
  create swarm:gate:budget       FBCA04 "waiting: cost cap reached; /swarm approve to raise it, /swarm park or /swarm drop"
  create swarm:waiting:evidence  FBCA04 "waiting: CI / evidence workflow on the branch head"
  create swarm:parked            BFD4F2 "paused by /swarm park or a closed PR; /swarm resume"
  create swarm:dropped           BFD4F2 "abandoned by /swarm drop"
  create swarm:done              BFD4F2 "released and retro done"
  create swarm:blocked           B60205 "the swarm stopped on this issue; see the blocked:* label"
  create swarm:short             C2E0C6 "short path: no design/architecture stages, one lane"
  create swarm:lane              C2E0C6 "tracking sub-issue of a swarm issue; never dispatched"
  create swarm:hands-off         C2E0C6 "the swarm ignores this issue until the label is removed by hand"
  create blocked:agent-output    B60205 "a role produced no valid result; /swarm resume"
  create blocked:budget          B60205 "rework budget exhausted; /swarm redo <stage> resets it"
  create blocked:runaway         B60205 "too many dispatches in one hour; /swarm resume"
  create blocked:bad-handoff     B60205 "unknown stage/role, or the swarm's own configuration is broken"
  create blocked:evidence        B60205 "an evidence workflow failed to run or timed out"
  create blocked:stalled         B60205 "a stage has no live run, or its finaliser failed; /swarm resume"
  create blocked:fire            B60205 "the next run could not be started; /swarm resume re-fires it"
  create blocked:injection       B60205 "instruction-shaped input; human review"
  create blocked:duplicate       B60205 "triage found a duplicate; /swarm resume to proceed anyway"
  create blocked:conflict        B60205 "branch cannot be rebased on the default branch"
  create blocked:perimeter       B60205 "a role touched a protected path, a ref outside its branch, the state, or a non-approver merged"
  create blocked:auth            B60205 "CLAUDE_CODE_OAUTH_TOKEN rejected; renew it, then /swarm resume"
  create blocked:model           B60205 "requested model not honoured and require_model_map is on"
  create bug     D73A4A "triage: defect"
  create feature A2EEEF "triage: new behaviour"
  create chore   EDEDED "triage: maintenance"
  create size:S FEF2C0; create size:M FEF2C0; create size:L FEF2C0; create size:XL FEF2C0
  create prio:P0 B60205; create prio:P1 D93F0B; create prio:P2 FBCA04; create prio:P3 C5DEF5
  lanes=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    lanes=$(jq -r '.lanes // {} | keys[]' "$cfg" 2>/dev/null)
  fi
  for lane in $lanes; do create "area:$lane" D4C5F9 "triage: lane $lane"; done
  create area:both D4C5F9 "triage: more than one lane"
  local v1 cur
  for v1 in swarm:spec swarm:review swarm:demo swarm:pr blocked:self-dispatch; do
    cur=$(gh api "repos/$REPO/labels/$v1" --jq '.description // ""' 2>/dev/null) || continue
    case $cur in
      *"(v1, unused by v2)"*) ;;
      *) jq -n --arg d "${cur:+$cur }(v1, unused by v2)" '{description: $d}' \
           | gh api -X PATCH "repos/$REPO/labels/$v1" --input - >/dev/null 2>&1 || log "labels: could not suffix $v1" ;;
    esac
  done
  log "labels: installed on $REPO"
  exit 0
}

# ── projection ──────────────────────────────────────────────────────────────────

desired_set() { # <state.json> → one label per line
  jq -r '
    def stage_label: if (.status | IN("done", "dropped")) then empty else "swarm:\(.stage)" end;
    [ stage_label,
      (if .status == "gate" and .gate != null then "swarm:gate:\(.gate.name)" else empty end),
      (if .status == "evidence" then "swarm:waiting:evidence" else empty end),
      (if .status == "blocked" then "swarm:blocked", (if .blocked != null then "blocked:\(.blocked.reason)" else empty end) else empty end),
      (if .status == "parked" then "swarm:parked" else empty end),
      (if .status == "dropped" then "swarm:dropped" else empty end),
      (if .status == "done" then "swarm:done" else empty end),
      (if .path == "short" then "swarm:short" else empty end),
      (if .flags.hands_off == true then "swarm:hands-off" else empty end),
      (if (.triage | type) == "object" then
         (if (.triage.type | IN("bug", "feature", "chore")) then .triage.type else empty end),
         (if (.triage.size | type) == "string" and (.triage.size | IN("S", "M", "L", "XL")) then "size:\(.triage.size)" else empty end),
         (if (.triage.area | type) == "string" and (.triage.area | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) then "area:\(.triage.area)" else empty end),
         (if (.triage.prio | type) == "string" and (.triage.prio | test("^P[0-3]$")) then "prio:\(.triage.prio)" else empty end)
       else empty end)
    ] | unique | .[]' "$1"
}

cmd_desired() {
  local f=${1:-}
  [ -n "$f" ] && [ -f "$f" ] || die "desired: <state.json>"
  desired_set "$f"
  exit 0
}

cmd_project() {
  local issue=${1:-} f=${2:-} current desired l add=() rm=() payload
  [ -n "$issue" ] && [ -n "$f" ] || die "project: <issue> <state.json>"
  [ -f "$f" ] || die "project: no such file: $f"
  require_env REPO
  jq -e 'type == "object" and .v == 2' "$f" >/dev/null 2>&1 || die "project: $f is not a v2 state document"
  current=$(gh api "repos/$REPO/issues/$issue" --jq '.labels[].name' 2>/dev/null) \
    || die "project: cannot read the labels of #$issue — refusing to guess"
  desired=$(desired_set "$f")
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    is_managed "$l" || { [ "$l" = "swarm:hands-off" ] || continue; }
    printf '%s\n' "$current" | grep -qxF -- "$l" || add+=("$l")
  done <<< "$desired"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    is_managed "$l" || continue
    printf '%s\n' "$desired" | grep -qxF -- "$l" || rm+=("$l")
  done <<< "$current"
  if [ ${#add[@]} -gt 0 ]; then
    payload=$(printf '%s\n' "${add[@]}" | jq -R . | jq -s -c '{labels: .}')
    if printf '%s' "$payload" | gh api -X POST "repos/$REPO/issues/$issue/labels" --input - >/dev/null 2>&1; then
      printf '+%s\n' "${add[@]}"
    else
      log "project: could not add ${add[*]} to #$issue"
    fi
  fi
  for l in "${rm[@]}"; do
    if gh api -X DELETE "repos/$REPO/issues/$issue/labels/$l" >/dev/null 2>&1; then
      printf -- '-%s\n' "$l"
    else
      log "project: could not remove $l from #$issue (already gone?)"
    fi
  done
  exit 0
}

# ── reconcile (v1 residue) ──────────────────────────────────────────────────────

cmd_reconcile() {
  local r=${1:-${REPO:-}} issues n merged changed=0
  [ -n "$r" ] || die "reconcile: <owner/repo>"
  REPO=$r
  export REPO
  issues=$(gh_json --paginate "repos/$r/issues?state=closed&labels=swarm:pr&per_page=100" 2>/dev/null \
    | jq -r '.[]? | select(.pull_request == null) | .number') || issues=""
  for n in $issues; do
    merged=$(gh_json --paginate "repos/$r/issues/$n/timeline?per_page=100" 2>/dev/null \
      | jq -r '[.[]? | select(.event == "cross-referenced") | .source.issue // empty
                | select(.pull_request != null) | select(.pull_request.merged_at != null) | .number] | first // empty') || merged=""
    if [ -z "$merged" ]; then
      log "reconcile: #$n has no merged pull request referencing it — left as is"
      continue
    fi
    gh api -X DELETE "repos/$r/issues/$n/labels/swarm:pr" >/dev/null 2>&1 || log "reconcile: could not remove swarm:pr from #$n"
    printf '{"labels": ["swarm:done"]}' | gh api -X POST "repos/$r/issues/$n/labels" --input - >/dev/null 2>&1 \
      || log "reconcile: could not add swarm:done to #$n"
    printf '#%s: swarm:pr → swarm:done (merged PR #%s)\n' "$n" "$merged"
    changed=$((changed + 1))
  done
  log "reconcile: $changed issue(s) updated"
  exit 0
}

case ${1:-} in
  install) shift; cmd_install "$@" ;;
  project) shift; cmd_project "$@" ;;
  desired) shift; cmd_desired "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  *) sed -n '2,27p' "$0" >&2; exit 1 ;;
esac
