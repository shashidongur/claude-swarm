#!/usr/bin/env bash
# route.sh — applies pipeline.json's verdict_edges to a finished dispatch (spec §16.1.3,
# §2, §8.4, §9.2, §9.5, §10.1). Called by advance.sh after `dispatch-finished`, and by
# reconcile.sh when a routing state with a finished record is found again.
#
#   route.sh <issue> <key> [<run_id>]
#
# Reads: the verified state (status must be `routing` with current.key == key —
# anything else fires nothing, exit 0: `parked`/`dropped` name the successor in the
# final comment, every other status says what the issue is doing), the record's
# verdict, the handoff result.json under
# $RUN_DIR, the critic acceptance advance wrote to $RUN_DIR/advance/critic.json, the
# routing facts in $RUN_DIR/advance/facts.json (branch, pr, head, subissues), and the
# comment input in $RUN_DIR/advance/comment.json (re-rendered with the real "Next:").
#
# Edges (every transition here carries --arg from_key <key>, precondition status ==
# routing ∧ current.key == key — a state that moved on is a log line, never a write):
#   pass       critic fail → one rework (rework.jq, critic_rework) or gate:confidence;
#              next role in the stage (per_lane over state.lanes, on_short incl.
#              when_scan_changed / sensitive_only), CI evidence between dev and review
#              (evidence.sh wait; red → rework:dev:<lane> with the log tail; pending →
#              status evidence), the stage gate (gate-enter + gate comment; release →
#              PR comment naming approvers.release), else the next stage on the path
#              (evidence_before → G29(f)/G31/G39 → evidence.sh fire; else its first
#              role); before release the blast radius (§9.5); retro → memory-pr.sh,
#              branch delete when delete_merged_branches ∧ the merge was an approver's,
#              `done`.
#   rework     G7 inside the rework transition (exit 5 → blocked:budget); target from
#              verdict_edges (`<lane>` = the current lane, `{result.rework_to}` = the
#              role's field); rework_max per source role → proceeds as pass with a ⚠
#   question   question comment (D15) + gate-enter question (records the comment id)
#   duplicate  block duplicate (swarm:blocked + blocked:duplicate; /swarm resume proceeds)
#   blocked    block injection (reason starts "injection:") or agent-output
# Every fire goes through fire.sh (claim, verify; blocked:fire + exit 1 on failure);
# every queue passes G8 (known role), G6 (runaway), G30 (cost cap → gate budget), G31
# (monthly brake before a write-role dispatch → gate budget).
#
# Environment: REPO, SWARM_STATE_KEY, CONFIG_JSON, RUN_DIR (default .swarm-run),
# WORKFLOW_REF or STUB_FILE, GH_TOKEN, RUN_ID; SWARM_TOKEN / SWARM_REPO / SWARM_REF and
# MEMORY_CHECKOUT for retro; SWARM_NOW for snapshots.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${1:-}
KEY=${2:-}
RUN_ID=${3:-${RUN_ID:-${GITHUB_RUN_ID:-0}}}
[ -n "$ISSUE" ] && [ -n "$KEY" ] || die "usage: route.sh <issue> <key> [<run_id>]"
require_env REPO SWARM_STATE_KEY
export ISSUE RUN_ID
RUN_DIR=${RUN_DIR:-.swarm-run}
ADV="$RUN_DIR/advance"
mkdir -p "$ADV"
LOGF="$RUN_DIR/advance.log"
log() { printf '%s\n' "$*" >&2; printf '%s route: %s\n' "$(now)" "$*" >> "$LOGF" 2>/dev/null || true; }
PIPELINE="$SWARM_ROOT/pipeline.json"
[ -f "$PIPELINE" ] || die "route: $PIPELINE is missing"
RESULT="$RUN_DIR/result.json"
FACTS="$ADV/facts.json"
CRITIC="$ADV/critic.json"
COMMENT_IN="$ADV/comment.json"
[ -f "$FACTS" ] || printf '{}' > "$FACTS"

P() { jq -r "$1 // empty" "$PIPELINE" 2>/dev/null; }
C() { [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ] && jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null; }
R() { [ -f "$RESULT" ] && jq -r "$1 // empty" "$RESULT" 2>/dev/null; }

# ── state ───────────────────────────────────────────────────────────────────────

STATE=$(tmpf .json) || die "route: no temp dir"
reload() {
  local rc=0
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null || rc=$?
  case $rc in
    0) ;;
    3) die "route: no state for #$ISSUE" ;;
    6) die "route: state #$ISSUE has an invalid signature — not routing" ;;
    *) die "route: cannot read state #$ISSUE" ;;
  esac
}
reload
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
SD() { local v; v=$(S "$1"); printf '%s' "${v:-$2}"; }   # with a default
SJ() { jq -c "$1" "$STATE" 2>/dev/null; }
WARNINGS=()
FACT_ARGS=()

STATUS=$(S '.status')
STAGE=$(S '.stage')
CUR_KEY=$(S '.current.key')
CUR_ROLE=$(S '.current.role')
ROLE=${CUR_ROLE%%:*}
LANE=""
[ "$CUR_ROLE" != "$ROLE" ] && LANE=${CUR_ROLE#*:}
PATHK=$(S '.path'); PATHK=${PATHK:-full}
VERDICT=$(jq -r --arg k "$KEY" --argjson r "$RUN_ID" '[(.dispatches // [])[] | select(.key == $k and .run_id == $r)] | last | .verdict // empty' "$STATE")
REC_STATUS=$(jq -r --arg k "$KEY" --argjson r "$RUN_ID" '[(.dispatches // [])[] | select(.key == $k and .run_id == $r)] | last | .status // empty' "$STATE")
REC_STAGE=$(jq -r --arg k "$KEY" --argjson r "$RUN_ID" '[(.dispatches // [])[] | select(.key == $k and .run_id == $r)] | last | .stage // empty' "$STATE")
[ -n "$REC_STAGE" ] && STAGE=$REC_STAGE
ARTIFACTS_DIR=$(C '.artifacts_dir'); ARTIFACTS_DIR=${ARTIFACTS_DIR:-docs/swarm}
DEFAULT=$(C '.default_branch'); DEFAULT=${DEFAULT:-main}
BRANCH=$(S '.branch')
[ -n "$BRANCH" ] || BRANCH=$(jq -r '.branch // empty' "$FACTS")
HEAD=$(S '.head')
[ -n "$HEAD" ] || HEAD=$(jq -r '.head // empty' "$FACTS")
export RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
MERGED=$(S '.merged_at')

# ── the final comment ───────────────────────────────────────────────────────────

comment_id() {
  local id
  id=$(cat "$ADV/comment-id" 2>/dev/null)
  [ -n "$id" ] || id=$(S '.current.comment_id')
  printf '%s' "$id"
}

# finish_comment <next text>: re-render the stage comment with the real successor and
# the warnings routing collected
finish_comment() {
  local next=$1 body id
  [ -f "$COMMENT_IN" ] || return 0
  jq -c --arg n "$next" '.next = $n | .warnings = ((.warnings // []) + $ARGS.positional | unique)' "$COMMENT_IN" --args "${WARNINGS[@]}" > "$COMMENT_IN.tmp" && mv "$COMMENT_IN.tmp" "$COMMENT_IN"
  body=$(tmpf .md) || return 0
  "$SWARM_LIB/render.sh" comment "$COMMENT_IN" "$body" --arg repo "$REPO" || { rm -f "$body"; log "cannot render the stage comment"; return 0; }
  id=$(comment_id)
  if [ -n "$id" ] && [ "$id" != null ]; then
    edit_comment "$id" "$body" || log "could not edit comment $id"
  else
    id=$(post_comment "$ISSUE" "$body") && printf '%s' "$id" > "$ADV/comment-id"
  fi
  rm -f "$body"
}

project_labels() {
  reload
  if [ -x "$SWARM_LIB/labels.sh" ]; then
    "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" || log "labels.sh project failed"
  fi
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "state comment not re-rendered"
}

# ── helpers over the pipeline ───────────────────────────────────────────────────

role_entry() { # <base role> → its entry (any stage)
  jq -c --arg r "$1" '[.stages[].roles[] | select(.name == $r)] | first // empty' "$PIPELINE"
}
stage_entry() { jq -c --arg s "$1" '[.stages[] | select(.name == $s)] | first // empty' "$PIPELINE"; }
stage_of_role() { jq -r --arg r "$1" '[.stages[] | select(any(.roles[]; .name == $r)) | .name] | first // empty' "$PIPELINE"; }
tier_model() { jq -r --arg t "$1" '.models.tiers[$t] // empty' "$PIPELINE"; }
role_model() { local e; e=$(role_entry "$1"); tier_model "$(printf '%s' "$e" | jq -r '.tier // "default"')"; }

approver_for() { # <gate> → one login (the first), or a placeholder
  local a
  a=$(approvers_for "$1" 2>/dev/null | head -1)
  printf '%s' "${a:-owner}"
}
approvers_text() { approvers_for "$1" 2>/dev/null | sed 's/^/@/' | paste -sd, - | sed 's/,/, /g'; }

# branch touches: the whole branch diff against the default branch
TOUCHES_CACHE=""
touches() {
  if [ -z "$TOUCHES_CACHE" ]; then
    TOUCHES_CACHE="-"
    if [ -n "$HEAD" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git fetch -q origin >/dev/null 2>&1 || true
      TOUCHES_CACHE=$(git diff --name-only "origin/$DEFAULT...$HEAD" 2>/dev/null || true)
      [ -n "$TOUCHES_CACHE" ] || TOUCHES_CACHE="-"
    fi
  fi
  [ "$TOUCHES_CACHE" = "-" ] || printf '%s\n' "$TOUCHES_CACHE"
}
touches_match() { # <config key of a glob list> → 0 when any touched path matches
  local -a globs
  mapfile -t globs < <(C ".[\"$1\"][]")
  [ ${#globs[@]} -gt 0 ] || return 1
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    matches_glob "$f" "${globs[@]}" && return 0
  done < <(touches)
  return 1
}

# the CI manifest on head, for on_short: when_scan_changed
SCAN_CHANGED=""
scan_changed() {
  if [ -z "$SCAN_CHANGED" ]; then
    local dir="$ADV/evidence" mf
    mkdir -p "$dir"
    [ -n "$HEAD" ] && "$SWARM_LIB/evidence.sh" collect "$ISSUE" "$HEAD" "$dir" >/dev/null 2>&1 || true
    mf="$dir/CI/manifest.json"
    if [ -f "$mf" ] && jq -e '.synthetic != true' "$mf" >/dev/null 2>&1; then
      if jq -e '
        def n: if type == "number" then . elif type == "array" then length elif type == "object" then ([.[] | n] | add // 0) else 0 end;
        (.sections // {}) | ((.sast.new // 0 | n) > 0) or ((.audit.new // 0 | n) > 0) or (.sast.changed == true) or (.audit.changed == true)
        or ([.audit | objects | .[]? | objects | (.new // 0 | n)] | add // 0) > 0' "$mf" >/dev/null 2>&1; then SCAN_CHANGED=yes; else SCAN_CHANGED=no; fi
    else
      SCAN_CHANGED=yes   # no manifest: the role runs and says what it could not read
    fi
  fi
  [ "$SCAN_CHANGED" = yes ]
}

# should_run <role token> → 0 when the role runs on this issue (on_short, lane status)
should_run() {
  local token=$1 base=${1%%:*} lane="" e os st
  [ "$token" != "$base" ] && lane=${token#*:}
  e=$(role_entry "$base")
  [ -n "$e" ] || return 1
  if [ -n "$lane" ]; then
    st=$(jq -r --arg s "$STAGE" --arg l "$lane" '(.stages[$s].lanes // {})[$l] // "pending"' "$STATE")
    [ "$st" = "done" ] && return 1
  fi
  os=$(printf '%s' "$e" | jq -r '.on_short // "run"')
  [ "$PATHK" = short ] || return 0
  case $os in
    skip) return 1 ;;
    when_scan_changed) scan_changed ;;
    sensitive_only) touches_match sensitive_paths ;;
    *) return 0 ;;
  esac
}

# expand <stage> → the stage's role tokens in order (per_lane over state.lanes)
expand() {
  local s=$1
  jq -r --arg s "$s" --argjson lanes "$(SJ '.lanes // []')" '
    [.stages[] | select(.name == $s) | .roles[]] as $roles
    | ($roles | map(select(.per_lane != true)) | map(.name)) as $plain
    | ($roles | map(select(.per_lane == true)) | map(.name)) as $per
    | ($roles | map(.per_lane == true) | index(true)) as $first_lane_idx
    | (if $first_lane_idx == null then $plain
       else ($roles[:$first_lane_idx] | map(.name))
            + [ $lanes[] as $l | $per[] | "\(.):\($l)" ]
            + ($roles[$first_lane_idx:] | map(select(.per_lane != true)) | map(.name))
       end)
    | .[]' "$PIPELINE"
}

# next_role_in_stage <stage> <after token|""> → the next runnable token (empty when none)
next_role_in_stage() {
  local s=$1 after=$2 t seen=0
  [ -n "$after" ] || seen=1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ $seen -eq 0 ]; then [ "$t" = "$after" ] && seen=1; continue; fi
    if should_run "$t"; then printf '%s\n' "$t"; return 0; fi
  done < <(expand "$s")
  return 1
}

# next_stage_after <stage> → the next stage on the path that is not skipped (empty when none)
next_stage_after() {
  jq -r --arg p "$PATHK" --arg s "$1" --argjson paths "$(jq -c '.paths' "$PIPELINE")" '
    (.stages) as $st
    | $paths[$p] as $path
    | ($path | index($s)) as $i
    | if $i == null then empty else
        [ $path[($i + 1):][] | select(($st[.].status // "pending") | IN("skipped", "skipped_by_owner") | not) ] | first // empty
      end' "$STATE"
}

runaway_tripped() {
  local limit n
  limit=$(C '.limits.runaway_per_hour'); [ -n "$limit" ] || limit=$(P '.limits.runaway_per_hour'); limit=${limit:-10}
  n=$(jq -r --arg now "$(now)" '[(.dispatches // [])[] | select(.at != null) | select(((($now | fromdateiso8601) - (.at | fromdateiso8601))) < 3600)] | length' "$STATE")
  [ "${n:-0}" -ge "$limit" ]
}

cost_cap() { # → the cap for this issue (0 = off)
  local cap
  cap=$(S '.limits.cost_usd_per_issue')
  [ -n "$cap" ] && [ "$cap" != null ] || cap=$(C '.limits.cost_usd_per_issue')
  [ -n "$cap" ] || cap=$(P '.limits.cost_usd_per_issue')
  printf '%s' "${cap:-75}"
}
estimate_for() { # <base role> → a USD estimate by tier
  case $(role_entry "$1" | jq -r '.tier // "default"') in
    cheap) printf '0.5' ;;
    strong) printf '8' ;;
    *) printf '4' ;;
  esac
}

# monthly_brake → prints "<used>/<limit> min" when the brake is on (G31), else nothing
monthly_brake() {
  local limit used env_min owner
  limit=$(C '.limits.runner_minutes_month'); [ -n "$limit" ] || limit=$(P '.limits.runner_minutes_month'); limit=${limit:-1500}
  owner=${OWNER:-${REPO%%/*}}
  used=$("$SWARM_LIB/state.sh" billing-used "$owner" 2>/dev/null)
  if [ -z "$used" ]; then
    used=$("$SWARM_LIB/state.sh" month-totals "$REPO" 2>/dev/null | jq -r '.minutes // 0' 2>/dev/null)
  fi
  used=${used%%.*}; used=${used:-0}
  case $PATHK in short) env_min=175 ;; *) env_min=300 ;; esac
  if [ $((used + env_min)) -gt "$limit" ]; then printf '%s/%s min' "$used" "$limit"; fi
}

block() { # <reason> <detail> [comment-next-text]
  local reason=$1 detail=$2 rc=0
  log "blocked:$reason — $detail"
  "$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason "$reason" --arg detail "$detail" --arg from_key "$KEY" >/dev/null || rc=$?
  [ $rc -eq 0 ] || log "block $reason not recorded (state.sh exit $rc)"
  finish_comment "${3:-blocked:$reason — $detail}"
  project_labels
}

# ── queue + fire ────────────────────────────────────────────────────────────────

# queue_and_fire <stage> <role token> <reason> [extra transition args…]
queue_and_fire() {
  local stage=$1 token=$2 reason=$3 base=${2%%:*} rc=0 model brake cap total est nk
  shift 3
  if [ -z "$(role_entry "$base")" ] || [ -z "$(stage_entry "$stage")" ]; then
    block bad-handoff "unknown stage/role $stage/$token"
    return 1
  fi
  if runaway_tripped; then
    block runaway "dispatches in the last hour reached the runaway limit before firing $token"
    return 1
  fi
  model=$(role_model "$base")
  local qerr
  qerr=$(tmpf .err) || die "route: no temp dir"
  "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-queued --arg stage "$stage" --arg role "$token" --arg reason "$reason" \
    --arg from_key "$KEY" --arg model "$model" "$@" >/dev/null 2>"$qerr" || rc=$?
  case $rc in
    0) rm -f "$qerr" ;;
    5)
      reload
      if [ "$(S '.status')" = routing ] && [ "$(S '.current.key')" = "$KEY" ]; then
        block bad-handoff "$token could not be queued: $(tail -n 1 "$qerr" | sed 's/^state: precondition: //' | head -c 300)"
        rm -f "$qerr"
        return 1
      fi
      log "state moved on before $token could be queued — nothing fired"
      rm -f "$qerr"
      return 0 ;;
    *) rm -f "$qerr"; die "route: cannot queue $token (state.sh exit $rc)" ;;
  esac
  reload
  nk=$(S '.next.key')
  # G30 — the cost cap is a wait-state, not a death
  cap=$(cost_cap)
  total=$(S '.totals.cost_usd'); total=${total:-0}
  est=$(estimate_for "$base")
  if [ "${cap%%.*}" != 0 ] && jq -en --arg t "$total" --arg e "$est" --arg c "$cap" '($t | tonumber) + ($e | tonumber) >= ($c | tonumber)' >/dev/null 2>&1; then
    budget_gate "$stage" "$token" "$total" "$cap" "$est" ""
    return 0
  fi
  # G31 — the monthly brake before a write-role dispatch
  if [ "$(role_entry "$base" | jq -r '.class // "read"')" = write ]; then
    brake=$(monthly_brake)
    if [ -n "$brake" ]; then
      budget_gate "$stage" "$token" "$total" "$cap" "$est" "monthly budget: $brake"
      return 0
    fi
  fi
  finish_comment "$token ($nk)"
  "$SWARM_LIB/fire.sh" "$ISSUE" "$stage" "$token" "$nk" "$reason" >/dev/null || rc=$?
  if [ $rc -ne 0 ]; then
    log "fire of $nk failed (fire.sh exit $rc)"
    project_labels
    return 1
  fi
  project_labels
  return 0
}

budget_gate() { # <stage> <token> <total> <cap> <estimate> <note>
  local stage=$1 token=$2 total=$3 cap=$4 est=$5 note=$6 body cid rc=0 newcap
  newcap=$(jq -n --arg c "$cap" --arg e "$(C '.limits.cost_usd_per_issue')" '($c | tonumber) + (($e | if . == "" then "75" else . end) | tonumber)')
  body=$(tmpf .md) || die "route: no temp dir"
  "$SWARM_LIB/render.sh" gate-budget "$body" --arg approver "$(approver_for default)" --arg cost "$total" --arg cap "$cap" \
    --arg issue "$ISSUE" --arg next "$token${note:+ — $note}" --arg estimate "$est" \
    --arg runner_minutes "$(SD '.totals.runner_minutes' 0)" --arg overhead_minutes "$(SD '.totals.overhead_minutes' 0)" \
    --arg new_cap "$newcap" --arg marker "$(marker gate "gate=budget" "key=$KEY" "stage=$stage")" || die "route: cannot render the budget comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred gate "gate=budget" "key=$KEY")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "could not edit the budget comment"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "could not post the budget comment"
  fi
  rm -f "$body"
  "$SWARM_LIB/state.sh" write "$ISSUE" gate-enter --arg name budget ${cid:+--arg comment_id "$cid"} >/dev/null || rc=$?
  [ $rc -eq 0 ] || log "gate budget not recorded (state.sh exit $rc)"
  finish_comment "$token — waiting: cost cap (${note:-\$$total of \$$cap}); /swarm approve raises it"
  project_labels
}

# ── gates ───────────────────────────────────────────────────────────────────────

gate_summary() {
  local s art critic
  s=$(R '.summary' | head -c 600)
  art=$(R '.artifacts | join(", ")')
  critic=$(jq -r 'if .accepted == true then "Critic score \(.score)/\(.threshold): \(.verdict)." else empty end' "$CRITIC" 2>/dev/null)
  printf '%s\n%s%s' "${s:-(no summary)}" "${art:+Artifacts on the branch under $ARTIFACTS_DIR/$ISSUE/: $art. }" "$critic"
}

enter_gate() { # <gate name> <done stage>
  local gate=$1 done_stage=$2 body cid rc=0 next_stage instr approver
  next_stage=$(next_stage_after "$done_stage")
  approver=$(approver_for "$gate")
  case $gate in
    release)
      instr="Merge PR #$(S '.pr') to release (the merge must be made by $(approvers_text release)); \`/swarm reject <why>\` or \`/swarm redo <stage> <why>\` otherwise." ;;
    *)
      instr="Reply \`/swarm approve\` to continue to ${next_stage:-the next stage}, or \`/swarm reject <why>\` to send it back to $(stage_entry "$done_stage" | jq -r '.gate.reject_to // "the stage"')." ;;
  esac
  body=$(tmpf .md) || die "route: no temp dir"
  "$SWARM_LIB/render.sh" gate "$body" --arg gate "$gate" --arg approver "$approver" --sarg summary "$(gate_summary)" \
    --arg cost "$(SD '.totals.cost_usd' 0)" --arg runner_minutes "$(SD '.totals.runner_minutes' 0)" \
    --arg instruction "$instr" --arg marker "$(marker gate "gate=$gate" "key=$KEY" "stage=$done_stage")" || die "route: cannot render the gate comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred gate "gate=$gate" "key=$KEY")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "could not edit the gate comment"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "could not post the gate comment"
  fi
  rm -f "$body"
  if [ "$gate" = release ] && [ -n "$(S '.pr')" ]; then
    body=$(tmpf .md) || die "route: no temp dir"
    "$SWARM_LIB/render.sh" pr-comment "$body" --arg issue "$ISSUE" --arg approvers "$(approvers_text release)" \
      --sarg summary "$(R '.summary' | head -c 600)" --arg marker "$(marker gate "gate=release" "key=$KEY")" \
      && { post_comment "$(S '.pr')" "$body" >/dev/null || log "could not post the PR comment"; }
    rm -f "$body"
  fi
  load_facts
  "$SWARM_LIB/state.sh" write "$ISSUE" gate-enter --arg name "$gate" --arg from_key "$KEY" --arg done_stage "$done_stage" \
    ${cid:+--arg comment_id "$cid"} "${FACT_ARGS[@]}" >/dev/null || rc=$?
  case $rc in
    0) ;;
    5) log "state moved on before the $gate gate was recorded" ;;
    *) die "route: cannot record the $gate gate (state.sh exit $rc)" ;;
  esac
  finish_comment "gate $gate — waiting for $(approvers_text "$gate")"
  project_labels
}

load_facts() { # the routing facts → FACT_ARGS (transition args), values never split
  FACT_ARGS=()
  local line
  while IFS= read -r line; do FACT_ARGS+=("$line"); done < <(jq -r 'to_entries[] | select(.value != null) | "--arg", .key, (.value | if type == "string" then . else tojson end)' "$FACTS" 2>/dev/null)
}

# ── the pass edge ───────────────────────────────────────────────────────────────

close_subissues_if_done() {
  if ! jq -e --arg s "$STAGE" '(.stages[$s].lanes // {}) | to_entries | all(.value == "done")' "$STATE" >/dev/null 2>&1; then return 0; fi
  "$SWARM_LIB/subissues.sh" close "$ISSUE" "Done in $BRANCH ($(S '.head' | cut -c1-12)); the lane's review passed." >/dev/null 2>&1 || log "sub-issues not closed"
}

blast_radius_ok() { # before release: lines/files against the default branch
  local lines files maxl maxf stat
  maxl=$(C '.limits.pr_lines'); [ -n "$maxl" ] || maxl=$(P '.limits.pr_lines'); maxl=${maxl:-800}
  maxf=$(C '.limits.pr_files'); [ -n "$maxf" ] || maxf=$(P '.limits.pr_files'); maxf=${maxf:-25}
  [ -n "$HEAD" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git fetch -q origin >/dev/null 2>&1 || true
  stat=$(git diff --numstat "origin/$DEFAULT...$HEAD" -- . ":(exclude)$ARTIFACTS_DIR/**" 2>/dev/null) || return 0
  files=$(printf '%s\n' "$stat" | sed '/^$/d' | wc -l | tr -d ' ')
  lines=$(printf '%s\n' "$stat" | awk '{ a += ($1 == "-" ? 0 : $1); d += ($2 == "-" ? 0 : $2) } END { print a + d + 0 }')
  if [ "$files" -gt "$maxf" ] || [ "$lines" -gt "$maxl" ]; then
    BLAST="the pull request changes $lines lines in $files files (limits $maxl lines / $maxf files)"
    return 1
  fi
  return 0
}

fire_evidence_before() { # <stage> → 0 when the wait started (stop), 1 when nothing was fired
  local stage=$1 e slot when brake outf rc=0 key consumer
  e=$(stage_entry "$stage" | jq -c '.evidence_before // empty')
  [ -n "$e" ] || return 1
  slot=$(printf '%s' "$e" | jq -r '.workflow')
  if [ "$PATHK" = short ] && [ "$(printf '%s' "$e" | jq -r '.on_short // "run"')" = skip ]; then return 1; fi
  when=$(printf '%s' "$e" | jq -r '.when // empty')
  local nwhen=0
  [ -n "$when" ] && nwhen=$(C ".[\"$when\"] | length")
  if [ -n "$when" ] && [ "${nwhen:-0}" != 0 ] && ! touches_match "$when"; then
    log "evidence $slot not fired: no touched path matches $when"
    return 1
  fi
  [ -n "$HEAD" ] || { log "evidence $slot not fired: no head"; return 1; }
  if touches | grep -qE '^\.github/'; then
    block perimeter "the branch diff touches .github/** — an evidence workflow will not be fired on it; a human reads the diff first (git diff origin/$DEFAULT...$HEAD -- .github)"
    return 0
  fi
  consumer=$(next_role_in_stage "$stage" "") || consumer=""
  [ -n "$consumer" ] || consumer=$(stage_entry "$stage" | jq -r '.roles[0].name')
  key=$("$SWARM_LIB/state.sh" next-key "$STATE" "$stage" evidence)
  brake=$(monthly_brake)
  outf=$(tmpf .out) || die "route: no temp dir"
  load_facts
  if [ -n "$brake" ]; then
    SWARM_MONTHLY_BRAKE="$brake" GITHUB_OUTPUT=$outf EVIDENCE_DIR="$ADV/evidence" "$SWARM_LIB/evidence.sh" fire "$ISSUE" "$slot" "$HEAD" "$key" "$consumer" \
      --arg from_key "$KEY" --arg stage "$stage" "${FACT_ARGS[@]}" >/dev/null || rc=$?
  else
    GITHUB_OUTPUT=$outf EVIDENCE_DIR="$ADV/evidence" "$SWARM_LIB/evidence.sh" fire "$ISSUE" "$slot" "$HEAD" "$key" "$consumer" \
      --arg from_key "$KEY" --arg stage "$stage" "${FACT_ARGS[@]}" >/dev/null || rc=$?
  fi
  if grep -q '^evidence_fired=true' "$outf"; then
    rm -f "$outf"
    finish_comment "evidence $slot on ${HEAD:0:7} ($key) → $consumer"
    project_labels
    return 0
  fi
  local reason
  reason=$(sed -n 's/^evidence_reason=//p' "$outf" | head -1)
  rm -f "$outf"
  if [ $rc -eq 1 ]; then
    log "evidence fire of $slot failed (blocked:fire)"
    project_labels
    exit 1
  fi
  if [ -n "$reason" ]; then
    "$SWARM_LIB/state.sh" write "$ISSUE" log --arg event evidence-skipped --arg note "$slot: $reason" >/dev/null 2>&1 || true
    WARNINGS+=("evidence $slot skipped — $reason")
  fi
  return 1
}

BLAST=""

# ci_gate <next token> → 0 continue, 1 stop (waiting or reworked)
ci_gate() {
  local next=$1 outf st concl rid tail lane rc=0 tailf
  [ -n "$HEAD" ] || { log "no head to wait for CI on"; return 0; }
  outf=$(tmpf .out) || die "route: no temp dir"
  GITHUB_OUTPUT=$outf "$SWARM_LIB/evidence.sh" wait ci "$HEAD" "$next" >/dev/null 2>&1 || rc=$?
  [ $rc -eq 0 ] || { rm -f "$outf"; die "route: evidence.sh wait failed (exit $rc)"; }
  st=$(sed -n 's/^evidence_status=//p' "$outf" | head -1)
  concl=$(sed -n 's/^evidence_conclusion=//p' "$outf" | head -1)
  rid=$(sed -n 's/^evidence_run_id=//p' "$outf" | head -1)
  rm -f "$outf"
  if [ "$st" != complete ]; then
    finish_comment "CI on ${HEAD:0:7} → $next (waiting for the workflow_run event)"
    project_labels
    return 1
  fi
  if [ "$concl" = success ]; then return 0; fi
  # G23 — red CI goes back to the lane's dev with the failing job's log tail
  case $(role_entry "$ROLE" | jq -r '.ci_on_failure // empty') in
    continue) WARNINGS+=("CI on ${HEAD:0:7} concluded $concl; the stage continues (ci_on_failure: continue)"); return 0 ;;
  esac
  lane=$LANE
  [ -n "$lane" ] || lane=$(S '.lanes[0]')
  [ -n "$lane" ] || { block evidence "CI on ${HEAD:0:7} concluded $concl and no lane is known to rework"; return 1; }
  tailf=$(tmpf .log) || die "route: no temp dir"
  [ -n "$rid" ] && [ "$rid" != 0 ] && gh run view -R "$REPO" "$rid" --log-failed 2>/dev/null | tail -n 120 > "$tailf"
  tail=$(redact < "$tailf" | tail -c 1800)
  rm -f "$tailf"
  do_rework ci-red "dev:$lane" build "CI on ${HEAD:0:7} concluded $concl (run $rid). Failing job log tail:
$tail"
  return 1
}

# do_rework <from> <to token> <target stage> <reason> [extra args…]
do_rework() {
  local from=$1 to=$2 stage=$3 reason=$4 rc=0 nk
  shift 4
  if [ -z "$(role_entry "${to%%:*}")" ]; then block bad-handoff "rework target $to is not a role"; return 1; fi
  if runaway_tripped; then block runaway "dispatches in the last hour reached the runaway limit before the rework of $to"; return 1; fi
  load_facts
  "$SWARM_LIB/state.sh" write "$ISSUE" rework --arg from "$from" --arg to "$to" --arg stage "$stage" --arg reason "$reason" \
    --arg from_key "$KEY" --arg model "$(role_model "${to%%:*}")" "$@" "${FACT_ARGS[@]}" >/dev/null || rc=$?
  case $rc in
    0) ;;
    5)
      reload
      if [ "$(S '.status')" = routing ]; then
        block budget "rework budget exhausted ($(S '.rework.spent')/$(S '.rework.budget')) — $from asked for $to; /swarm reject <why> or /swarm redo <stage> resets it"
      else
        log "state moved on before the rework of $to was recorded"
      fi
      return 1 ;;
    *) die "route: cannot record the rework of $to (state.sh exit $rc)" ;;
  esac
  reload
  nk=$(S '.next.key')
  finish_comment "$to ($nk) — rework: $(printf '%s' "$reason" | head -c 160 | tr '\n' ' ')"
  "$SWARM_LIB/fire.sh" "$ISSUE" "$stage" "$to" "$nk" rework >/dev/null || rc=$?
  project_labels
  [ $rc -eq 0 ] || return 1
  return 0
}

critic_screen() { # → 0 continue, 1 stopped (rework fired or confidence gate)
  [ -f "$CRITIC" ] && jq -e '.accepted == true and .verdict == "fail"' "$CRITIC" >/dev/null 2>&1 || return 0
  local conf reworks limit findings body cid rc=0
  conf=$(jq -r '.confidence // "medium"' "$CRITIC")
  reworks=$(jq -r --arg s "$STAGE" '.stages[$s].critic_reworks // 0' "$STATE")
  limit=$(C '.limits.critic_rework'); [ -n "$limit" ] || limit=$(P '.limits.critic_rework'); limit=${limit:-1}
  findings=$(jq -r '(.findings // [])[] | "- [\(.severity // "?")] \(.where // "?"): \(.claim // "") — \(.fix // "")"' "$CRITIC" | head -c 3000)
  if [ "$conf" != low ] && [ "$reworks" -lt "$limit" ] && jq -e '(.rework.spent // 0) < (.rework.budget // 0)' "$STATE" >/dev/null; then
    do_rework critic "$CUR_ROLE" "$STAGE" "critic $(jq -r '.rubric' "$CRITIC") scored $(jq -r '.score' "$CRITIC")/$(jq -r '.threshold' "$CRITIC"):
$findings" --arg critic_rework true
    return 1
  fi
  body=$(tmpf .md) || die "route: no temp dir"
  "$SWARM_LIB/render.sh" confidence "$body" --arg approver "$(approver_for confidence)" --arg rubric "$(jq -r '.rubric // "generic"' "$CRITIC")" \
    --arg stage "$STAGE" --arg score "$(jq -r '.score' "$CRITIC")" --arg threshold "$(jq -r '.threshold' "$CRITIC")" --arg confidence "$conf" \
    --arg reworks "$reworks" --sarg findings "${findings:-(no findings listed)}" \
    --arg marker "$(marker gate "gate=confidence" "key=$KEY" "stage=$STAGE")" || die "route: cannot render the confidence comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred gate "gate=confidence" "key=$KEY")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "could not edit the confidence comment"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "could not post the confidence comment"
  fi
  rm -f "$body"
  load_facts
  "$SWARM_LIB/state.sh" write "$ISSUE" gate-enter --arg name confidence --arg from_key "$KEY" --arg escalated_role "$CUR_ROLE" \
    ${cid:+--arg comment_id "$cid"} "${FACT_ARGS[@]}" >/dev/null || rc=$?
  [ $rc -eq 0 ] || log "confidence gate not recorded (state.sh exit $rc)"
  finish_comment "gate confidence — critic $(jq -r '.score' "$CRITIC")/$(jq -r '.threshold' "$CRITIC"), waiting for $(approvers_text confidence)"
  project_labels
  return 1
}

# role_facts: what a passing role adds to the state (folded into the routing CAS)
role_facts() {
  local f="$FACTS"
  case $ROLE in
    triage)
      local tri path
      tri=$(R '.triage | select(type == "object")')
      path=$(printf '%s' "$tri" | jq -r '.path // "full"')
      if jq -e '.downgraded["triage.path"] == "full"' "$ADV/validation.json" >/dev/null 2>&1; then path=full; fi
      [ "$path" = short ] || path=full
      jq -c --argjson t "${tri:-null}" --arg p "$path" '. + {triage: ($t | del(.path)), path: $p, path_source: "triage"}
        + (if $p == "short" and ($t.area // "") != "" and ($t.area // "") != "both" then {lanes: [$t.area]} else {} end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      PATHK=$path ;;
    analyst)
      if [ "$PATHK" = short ] && [ "$(R '.hints.path')" = full ]; then
        "$SWARM_LIB/state.sh" write "$ISSUE" path --arg path full --arg source analyst >/dev/null || log "path escalation not recorded"
        PATHK=full
        reload
        WARNINGS+=("the analyst escalated the issue to the full path")
      fi ;;
    planner)
      local lanes
      lanes=$(R '.hints.lanes | select(type == "array") | tojson')
      if [ -n "$lanes" ]; then
        lanes=$(jq -cn --argjson l "$lanes" --argjson cfg "$(C '.lanes | keys')" '[$cfg[] | select(. as $x | $l | index($x) != null)]')
      fi
      [ -n "$lanes" ] && [ "$lanes" != "[]" ] || lanes=$(SJ '.lanes // []')
      [ "$lanes" != "[]" ] || lanes=$(C '.lanes | keys' | jq -c .)
      jq -c --argjson l "$lanes" '. + {lanes: $l}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      jq -c --argjson l "$lanes" '.lanes = $l' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      if jq -e '.subissues | type == "array" and length > 0' "$RESULT" >/dev/null 2>&1; then
        local si
        si=$(BRANCH=$BRANCH "$SWARM_LIB/subissues.sh" create "$ISSUE" "$RESULT" 2>>"$LOGF") || si=""
        [ -n "$si" ] && jq -c --argjson s "$si" '. + {subissues: $s}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      fi ;;
    code-review)
      [ -n "$LANE" ] && jq -c --arg l "$LANE" '. + {done_lane: $l}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      jq -c --arg s "$STAGE" --arg l "$LANE" '.stages[$s].lanes[$l] = "done"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      close_subissues_if_done ;;
  esac
}

route_pass() {
  critic_screen || return 0
  role_facts
  local next stage_done cur=$STAGE next_stage first
  if [ "$ROLE" = retro ]; then retro_done; return 0; fi
  # CI evidence after a write role, and before any role that requires it
  next=$(next_role_in_stage "$STAGE" "$CUR_ROLE") || next=""
  if [ -n "$next" ]; then
    if [ "$(role_entry "$ROLE" | jq -r '.evidence_after // empty')" = ci ] || [ "$(role_entry "${next%%:*}" | jq -r '.requires_ci // empty')" = success ]; then
      ci_gate "$next" || return 0
    fi
    load_facts
    queue_and_fire "$STAGE" "$next" chain "${FACT_ARGS[@]}"
    return 0
  fi
  # the stage is complete: its gate, else the next stage on the path
  stage_done=$STAGE
  if [ "$(stage_entry "$STAGE" | jq -r '.gate | if type == "object" then .name else "none" end')" != none ]; then
    if [ "$PATHK" = full ] || [ "$(stage_entry "$STAGE" | jq -r '.gate.on_short // "run"')" != skip ]; then
      enter_gate "$(stage_entry "$STAGE" | jq -r '.gate.name')" "$STAGE"
      return 0
    fi
  fi
  jq -c --arg s "$stage_done" '. + {done_stage: $s}' "$FACTS" > "$FACTS.tmp" && mv "$FACTS.tmp" "$FACTS"
  while :; do
    next_stage=$(next_stage_after "$cur")
    if [ -z "$next_stage" ]; then
      log "no stage follows $cur on the $PATHK path — nothing to fire"
      finish_comment "nothing — $cur was the last stage on the $PATHK path"
      "$SWARM_LIB/state.sh" write "$ISSUE" stage-done --arg stage "$stage_done" --arg from_key "$KEY" >/dev/null 2>&1 || true
      project_labels
      return 0
    fi
    STAGE=$next_stage
    if [ "$next_stage" = release ] && ! blast_radius_ok; then
      release_refused "$stage_done"
      return 0
    fi
    if fire_evidence_before "$next_stage"; then return 0; fi
    first=$(next_role_in_stage "$next_stage" "") || first=""
    if [ -n "$first" ]; then
      if [ "$(role_entry "${first%%:*}" | jq -r '.requires_ci // empty')" = success ]; then ci_gate "$first" || return 0; fi
      load_facts
      queue_and_fire "$next_stage" "$first" chain "${FACT_ARGS[@]}"
      return 0
    fi
    log "stage $next_stage has no role to run on the $PATHK path — skipped"
    "$SWARM_LIB/state.sh" write "$ISSUE" stage-done --arg stage "$next_stage" --arg from_key "$KEY" >/dev/null 2>&1 || true
    reload
    cur=$next_stage
  done
}

release_refused() { # <done stage>: blast radius (§9.5) — visible, non-terminal
  local rc=0
  load_facts
  "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-queued --arg stage release --arg role release --arg reason chain --arg from_key "$KEY" \
    --arg model "$(role_model release)" "${FACT_ARGS[@]}" >/dev/null || rc=$?
  [ $rc -eq 0 ] || log "release could not be queued before parking (state.sh exit $rc)"
  "$SWARM_LIB/state.sh" write "$ISSUE" park --arg note "blast radius: $BLAST" >/dev/null || log "park not recorded"
  finish_comment "release — refused: $BLAST; split it: \`/swarm redo build\` (or \`/swarm resume\` to release anyway)"
  project_labels
}

retro_done() {
  local outf rc=0 mpr martifact mreason note body cid merged_by ok_merge=0
  outf=$(tmpf .out) || die "route: no temp dir"
  GITHUB_OUTPUT=$outf "$SWARM_LIB/memory-pr.sh" "$ISSUE" "$RESULT" "$STATE" >/dev/null 2>>"$LOGF" || rc=$?
  mpr=$(sed -n 's/^memory_pr=//p' "$outf" | head -1)
  martifact=$(sed -n 's/^memory_artifact=//p' "$outf" | head -1)
  mreason=$(sed -n 's/^memory_reason=//p' "$outf" | head -1)
  rm -f "$outf"
  if [ -n "$mpr" ]; then
    note="pull request $(jq -r '.memory.path // "memory"' "${CONFIG_JSON:-/dev/null}" 2>/dev/null) — ${SWARM_REPO:-swarm}#$mpr"
  else
    note="not written (${mreason:-unknown}); patch attached as artifact ${martifact:-swarm-$ISSUE-memory-patch} — apply with git am"
    body=$(tmpf .md) || die "route: no temp dir"
    "$SWARM_LIB/render.sh" memory-failed "$body" --sarg reason "${mreason:-unknown}" --arg artifact "${martifact:-swarm-$ISSUE-memory-patch}" \
      --arg marker "$(marker retro "key=$KEY" "topic=memory")" && { post_comment "$ISSUE" "$body" >/dev/null || true; }
    rm -f "$body"
  fi
  merged_by=$(S '.merged_by')
  if [ -n "$merged_by" ] && is_approver "$merged_by" release; then ok_merge=1; fi
  local branch_note="kept"
  if [ "$(C '.delete_merged_branches')" = true ] && [ $ok_merge -eq 1 ] && [ -n "$BRANCH" ] && [ -n "$(S '.merged_at')" ]; then
    if gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1; then branch_note="$BRANCH deleted"; else branch_note="$BRANCH could not be deleted"; fi
  elif [ $ok_merge -eq 0 ]; then
    branch_note="kept (the merge was not made by an approver, or the merge is unknown)"
  fi
  rc=0
  "$SWARM_LIB/state.sh" write "$ISSUE" "done" --arg from_key "$KEY" ${mpr:+--arg memory_pr "$mpr"} ${martifact:+--arg memory_artifact "$martifact"} >/dev/null || rc=$?
  [ $rc -eq 0 ] || log "done not recorded (state.sh exit $rc)"
  reload
  body=$(tmpf .md) || die "route: no temp dir"
  local st sumf
  sumf=$(tmpf .txt) || die "route: no temp dir"
  R '.summary' > "$sumf"
  st=$(jq -c --arg k "$KEY" '[(.dispatches // [])[] | select(.key == $k)] | last // {}' "$STATE")
  "$SWARM_LIB/render.sh" retro "$body" --arg model "$(printf '%s' "$st" | jq -r '.model_actual // .model_requested // "?"')" \
    --arg cost "$(printf '%s' "$st" | jq -r '.cost_usd // 0')" --arg turns "$(printf '%s' "$st" | jq -r '.turns // 0')" \
    --arg duration "$(printf '%s' "$st" | jq -r '(.duration_s // 0) | "\(. / 60 | floor)m\(. % 60)s"')" --arg job_minutes "$(printf '%s' "$st" | jq -r '.job_minutes // 0')" \
    --srawfile summary "$sumf" --sarg memory "$note" --sarg branch_note "$branch_note" \
    --arg total_cost "$(SD '.totals.cost_usd' 0)" --arg total_turns "$(SD '.totals.turns' 0)" \
    --arg runner_minutes "$(SD '.totals.runner_minutes' 0)" --arg overhead_minutes "$(SD '.totals.overhead_minutes' 0)" \
    --arg wakeups "$(SD '.totals.wakeups' 0)" --arg reworks "$(SD '.rework.spent' 0)" --arg rework_budget "$(SD '.rework.budget' 5)" \
    --arg marker "$(marker stage "stage=retro" "role=retro" "key=$KEY" "run=$RUN_ID" "status=finished" "verdict=pass")" || die "route: cannot render the retro comment"
  cid=$(comment_id)
  if [ -n "$cid" ] && [ "$cid" != null ]; then edit_comment "$cid" "$body" || log "could not edit comment $cid"; else post_comment "$ISSUE" "$body" >/dev/null || true; fi
  rm -f "$body" "$sumf"
  project_labels
}

# ── the other edges ─────────────────────────────────────────────────────────────

route_question() {
  local author atype approver n qs body cid rc=0 rounds max
  author=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.user.login // ""' 2>/dev/null)
  atype=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.user.type // ""' 2>/dev/null)
  approver=$(approver_for default)
  if [ "$atype" != User ] || [ "$(C '.reporter_may_answer')" = false ]; then author=$approver; fi
  n=$(R '.questions | length'); n=${n:-0}
  qs=$(R '.questions[] | "- \(.q)"')
  rounds=$(S '.questions.rounds'); rounds=${rounds:-0}
  max=$(S '.questions.max'); max=${max:-2}
  body=$(tmpf .md) || die "route: no temp dir"
  "$SWARM_LIB/render.sh" question "$body" --arg author "$author" --arg count "$n" --arg round "$((rounds + 1))" --arg max "$max" \
    --sarg questions "${qs:-(none listed)}" --arg marker "$(marker question "key=$KEY" "stage=$STAGE")" || die "route: cannot render the question comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred question "key=$KEY")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "could not edit the question comment"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "could not post the question comment"
  fi
  rm -f "$body"
  load_facts
  "$SWARM_LIB/state.sh" write "$ISSUE" gate-enter --arg name question --arg from_key "$KEY" ${cid:+--arg comment_id "$cid"} "${FACT_ARGS[@]}" >/dev/null || rc=$?
  case $rc in
    0) finish_comment "gate question — waiting for an answer from $author" ;;
    5) reload; if [ "$(S '.status')" = routing ]; then block bad-handoff "question rounds exhausted ($rounds/$max); the analyst must proceed on stated assumptions"; else log "state moved on"; fi; return 0 ;;
    *) die "route: cannot record the question gate (state.sh exit $rc)" ;;
  esac
  project_labels
}

route_rework() {
  local edge target lane
  edge=$(jq -r --arg r "$ROLE" '.verdict_edges["\($r).rework"] // .verdict_edges["*.rework"] // empty' "$PIPELINE")
  [ -n "$edge" ] || { block bad-handoff "no rework edge is defined for $ROLE"; return 0; }
  target=${edge#rework:}
  case $target in
    "{result.rework_to}") target=$(R '.rework_to') ;;
    *"<lane>"*) target=${target//<lane>/$LANE} ;;
  esac
  [ -n "$target" ] || { block bad-handoff "$ROLE returned rework without a target"; return 0; }
  local maxr taken
  maxr=$(role_entry "$ROLE" | jq -r '.rework_max // empty')
  if [ -n "$maxr" ]; then
    taken=$(jq -r --arg f "$CUR_ROLE" '[(.rework.log // [])[] | select(.from == $f)] | length' "$STATE")
    if [ "$taken" -ge "$maxr" ]; then
      WARNINGS+=("$ROLE asked for a rework of $target again (rework_max $maxr reached) — proceeding as pass")
      VERDICT=pass
      route_pass
      return 0
    fi
  fi
  do_rework "$CUR_ROLE" "$target" "$(stage_of_role "${target%%:*}")" "$(R '.reason' | head -c 2000)"
}

route_blocked() {
  local reason
  reason=$(R '.reason' | head -c 600)
  case $reason in
    injection:*) block injection "$reason" "blocked:injection — $reason; a human reads the input" ;;
    *) block agent-output "${reason:-$ROLE returned blocked without a reason}" "blocked:agent-output — ${reason:-no reason}; /swarm resume re-runs $CUR_ROLE at attempt $(( $(SD '.current.attempt' 1) + 1 ))" ;;
  esac
}

route_duplicate() {
  local dups
  dups=$(R '.duplicates | map("#\(.)") | join(", ")')
  block duplicate "duplicate of ${dups:-(unlisted)}: $(R '.reason' | head -c 400)" "blocked:duplicate of ${dups:-?} — close this issue, or /swarm resume to proceed anyway"
}

# ── dispatch ────────────────────────────────────────────────────────────────────

if [ "$CUR_KEY" != "$KEY" ]; then
  log "current is ${CUR_KEY:--}, not $KEY — nothing to route"
  exit 0
fi
case $STATUS in
  routing) ;;
  parked|dropped)
    next=$(next_role_in_stage "$STAGE" "$CUR_ROLE") || next=""
    [ -n "$next" ] || next="the $(next_stage_after "$STAGE" || printf 'next') stage"
    "$SWARM_LIB/state.sh" write "$ISSUE" log --arg event next-when-resumed --arg note "$next" >/dev/null 2>&1 || true
    finish_comment "$next — $STATUS; \`/swarm resume\` fires it"
    project_labels
    exit 0 ;;
  *)
    # the issue moved on while this run was in flight (a merge queued retro, a gate
    # dissolved, an owner command): the record is kept, nothing is fired, and the
    # comment still ends in a terminal form
    log "status is $STATUS — nothing to route"
    case $STATUS in
      queued) finish_comment "nothing fired by this run — the issue is queued for $(S '.next.role') ($(S '.next.key'))${MERGED:+ after the merge}" ;;
      evidence) finish_comment "nothing fired by this run — the issue is waiting for evidence $(S '.evidence.pending.workflow')" ;;
      gate) finish_comment "nothing fired by this run — the issue is at the $(S '.gate.name') gate" ;;
      done) finish_comment "nothing — the issue is done" ;;
      *) finish_comment "nothing fired by this run — the issue is $STATUS" ;;
    esac
    exit 0 ;;
esac
[ "$REC_STATUS" = finished ] || { log "record ($KEY, $RUN_ID) is ${REC_STATUS:-absent}, not finished — nothing to route"; exit 0; }
[ -n "$VERDICT" ] || { log "record ($KEY, $RUN_ID) has no verdict"; exit 0; }
log "routing $CUR_ROLE ($KEY) verdict $VERDICT on the $PATHK path"

edge=$(jq -r --arg r "$ROLE" --arg v "$VERDICT" '.verdict_edges["\($r).\($v)"] // .verdict_edges["*.\($v)"] // empty' "$PIPELINE")
case $VERDICT in
  pass) route_pass ;;
  rework) route_rework ;;
  question) route_question ;;
  duplicate) route_duplicate ;;
  blocked) route_blocked ;;
  *) block bad-handoff "verdict $VERDICT has no edge (${edge:-none})" ;;
esac
rm -f "$STATE" "$STATE.tmp"
exit 0
