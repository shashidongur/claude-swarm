#!/usr/bin/env bash
# resolve.sh — the event → intent mapper of the dispatcher (spec §3, §4.4, §5 event
# guards G1–G39, §6, §16.1.3). Runs in the `resolve` job for every event the cheap
# gate lets through; decides one of: a silent skip (`go=false`), a reply to the human
# who caused the event, a terminal refusal (`block=<reason>` for the refuse job), a
# state change plus a fire (human commands, evidence, a merge), the claim of a
# queued dispatch (`go=true` with every run-job output), or `finalize=true`.
#
# Order of the event guards (§16.1.3): body → file; intent by event (§3.4); G2 kill
# switch; config (G27, incl. an empty SWARM_STATE_KEY and a missing state branch);
# derive the issue (PR conversation → head branch; workflow_run → `swarm#N` or the
# branch); state read (G37: a bad signature is blocked:perimeter); pin the swarm
# checkout at state.swarm_sha; G10 (v1 markers are data); a hand-added
# swarm:hands-off → flags; G4 veto; G9 identity (+ G38); G17 admissibility; G16 key
# match and claim; G28; G33; G34; G35; G6/G7/G30/G31 before every fire; G8.
#
# Environment (all from the workflow, §16.1.1): REPO EVENT ACTION SENDER SENDER_TYPE
# ACTOR OWNER ISSUE COMMENT_ID LABEL_ADDED BODY ISSUE_AUTHOR ISSUE_AUTHOR_TYPE
# PR_MERGED PR_HEAD_REF PR_NUMBER PR_MERGED_BY PR_MERGED_BY_TYPE PR_MERGE_SHA
# WR_NAME WR_ID WR_SHA WR_EVENT WR_BRANCH WR_TITLE WR_CONCLUSION
# D_ISSUE D_STAGE D_ROLE D_KEY D_REASON RUN_ID RUN_ATTEMPT WORKFLOW_REF CONFIG_PATH
# SWARM_REF SWARM_REPO SWARM_STATE_KEY SWARM_TOKEN (billing endpoint only) GH_TOKEN.
# Outputs (§16.1.1): go finalize block reason event_id issue stage role lane class
# attempt key model retry_model critic_model critic_rubric critic_threshold max_turns
# timeout retry_timeout retry_allowed critic_turns critic_timeout job_timeout
# allowed_tools disallowed_tools write_roots protected deny branch head pr path
# swarm_sha working_comment_id base_sha evidence_json; STATE_JSON and CONFIG_JSON go
# to $GITHUB_ENV for pack-tree.sh.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

require_env REPO EVENT
PIPELINE="$SWARM_ROOT/pipeline.json"
[ -f "$PIPELINE" ] || die "resolve: pipeline.json missing at $SWARM_ROOT"
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
RUN_ATTEMPT=${RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}
export RUN_ID RUN_ATTEMPT
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
export RUN_URL
OWNER=${OWNER:-${REPO%%/*}}
export OWNER
SWARM_REF=${SWARM_REF:-v2}
ACTION=${ACTION:-}
SENDER=${SENDER:-}
SENDER_TYPE=${SENDER_TYPE:-}
ACTOR=${ACTOR:-}
ISSUE=${ISSUE:-}
COMMENT_ID=${COMMENT_ID:-}
LABEL_ADDED=${LABEL_ADDED:-}
D_ISSUE=${D_ISSUE:-}
D_STAGE=${D_STAGE:-}
D_ROLE=${D_ROLE:-}
D_KEY=${D_KEY:-}
D_REASON=${D_REASON:-manual}
PR_NUMBER=${PR_NUMBER:-}
PR_HEAD_REF=${PR_HEAD_REF:-}
PR_MERGED=${PR_MERGED:-}
WR_NAME=${WR_NAME:-}
WR_ID=${WR_ID:-}
WR_SHA=${WR_SHA:-}
WR_EVENT=${WR_EVENT:-}
WR_BRANCH=${WR_BRANCH:-}
WR_TITLE=${WR_TITLE:-}
WR_CONCLUSION=${WR_CONCLUSION:-}

# the comment body goes env → file; nothing from it is ever interpolated
BODY_FILE=$(tmpf .body) || die "resolve: no temp dir"
printf '%s' "${BODY:-}" > "$BODY_FILE"
unset BODY
STATE=$(tmpf .state) || die "resolve: no temp dir"
HAVE_STATE=0
WARN=""
CMD='{"verb": null}'
VERB=""

# ── small helpers ─────────────────────────────────────────────────────────────

S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
SJ() { jq -c "$1" "$STATE" 2>/dev/null; }
C() { jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null; }
P() { jq -r "$1 // empty" "$PIPELINE" 2>/dev/null; }
status() { S .status; }
ok_done() { # an accepted event that fires nothing more from this job
  out go false
  out reason "$1"
  out block ""
  printf 'OK: %s\n' "$1"
  exit 0
}
run_url_of() { printf 'https://github.com/%s/actions/runs/%s\n' "$REPO" "$1"; }

# write <transition> [args…]: state.sh write on this issue; the snapshot follows
write() {
  local rc=0 o e
  o=$(tmpf .w) || return 1
  e=$(tmpf .we) || return 1
  "$SWARM_LIB/state.sh" write "$ISSUE" "$@" > "$o" 2> "$e" || rc=$?
  if [ $rc -eq 0 ]; then mv -f "$o" "$STATE"; else cat "$e" >&2; rm -f "$o"; fi
  rm -f "$e"
  return $rc
}

projection() {
  "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" >/dev/null || log "resolve: labels.sh project failed"
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "resolve: state comment not re-rendered"
}

ack() { # <text>: the one-line acknowledgement (skip-if-exists per event id)
  reply "$ISSUE" "$EVENT_ID" "$1$WARN" >/dev/null || log "resolve: acknowledgement not posted"
}

# refuse_human <text>: reply once per login per day (G38), record it, stop
refuse_human() {
  local id
  id=$(reply "$ISSUE" "$EVENT_ID" "$1" "$SENDER") || log "resolve: refusal reply not posted"
  if [ -n "$id" ] && [ $HAVE_STATE -eq 1 ] && [ -n "$SENDER" ]; then
    write refusal --arg login "$SENDER" >/dev/null 2>&1 || true
  fi
  say "refused: $1"
}

is_human=0
case_is_human() { [ $is_human -eq 1 ]; }

# refuse_event <text>: a human gets a reply, a machine event a log line
refuse_event() {
  if case_is_human && [ -n "${ISSUE:-}" ]; then refuse_human "$1"; fi
  say "$1"
}

# ── pipeline / config lookups ──────────────────────────────────────────────

path_of() { local p; p=$(S .path); printf '%s\n' "${p:-full}"; }
first_lane() { S '.lanes[0]' ; }

role_entry() { # <stage> <role[:lane]> → the role's pipeline entry (json), empty when unknown
  jq -c --arg s "$1" --arg r "${2%%:*}" '.stages[] | select(.name == $s) | .roles[] | select(.name == $r)' "$PIPELINE" 2>/dev/null | head -1
}
stage_known() { jq -e --arg s "$1" 'any(.stages[]; .name == $s)' "$PIPELINE" >/dev/null 2>&1; }
lane_known() { [ -z "$1" ] || jq -e --arg l "$1" '.lanes | has($l)' "$CONFIG_JSON" >/dev/null 2>&1; }

# first_role <stage>: the stage's first role on this path (a per-lane role carries the first lane)
first_role() {
  jq -r --arg s "$1" --arg path "$(path_of)" --arg lane "$(first_lane)" '
    .stages[] | select(.name == $s) | .roles
    | map(select($path != "short" or ((.on_short // "run") != "skip")))
    | first | if . == null then empty elif .per_lane == true then "\(.name):\($lane)" else .name end' "$PIPELINE"
}

# next_stage_after <stage>: the next stage on the path that is not skipped (never retro)
next_stage_after() {
  jq -r --arg s "$1" --arg path "$(path_of)" --argjson st "$(SJ '.stages // {}')" '
    (.paths[$path] // .paths.full) as $p
    | ($p | index($s)) as $i
    | if $i == null then empty else
        [ $p[$i + 1:][] | select(. != "retro") | select(($st[.].status // "pending") | IN("skipped", "skipped_by_owner") | not) ] | first // empty
      end' "$PIPELINE"
}

# stage_gate <stage>: the gate name after the stage on this path ("" when none)
stage_gate() {
  jq -r --arg s "$1" --arg path "$(path_of)" '
    .stages[] | select(.name == $s) | .gate
    | if type != "object" then empty
      elif $path == "short" and ((.on_short // "run") == "skip") then empty
      else .name end' "$PIPELINE"
}

stage_on_path() { # <stage>
  jq -e --arg s "$1" --arg path "$(path_of)" '(.paths[$path] // .paths.full) | index($s) != null' "$PIPELINE" >/dev/null 2>&1 \
    && [ "$(S ".stages[\"$1\"].status")" != skipped ]
}

model_for_tier() { P ".models.tiers[\"$1\"]"; }
role_model() { # <stage> <role>
  local e t
  e=$(role_entry "$1" "$2")
  t=$(printf '%s' "$e" | jq -r '.tier // "default"')
  model_for_tier "$t"
}
role_class() { role_entry "$1" "$2" | jq -r '.class // "read"'; }

# ── the state comment for a human: one status line ────────────────────────

status_line() {
  local st stage hint cost rm om url
  st=$(status); stage=$(S .stage)
  cost=$(jq -r '((.totals.cost_usd // 0) * 100 | round / 100)' "$STATE")
  rm=$(S '.totals.runner_minutes'); om=$(S '.totals.overhead_minutes')
  case $st in
    gate)
      case $(S .gate.name) in
        release) hint="merge PR #$(S .pr) (an approver for release), or /swarm reject <why>" ;;
        question) hint="the reporter answers in plain text, or /swarm resume to proceed on assumptions" ;;
        budget) hint="/swarm approve raises the cap, /swarm park or /swarm drop" ;;
        *) hint="/swarm approve or /swarm reject <why> (gate $(S .gate.name))" ;;
      esac ;;
    blocked) hint="blocked:$(S .blocked.reason) — /swarm resume" ;;
    parked) hint="/swarm resume" ;;
    queued) hint="queued $(S .next.key) — run $(S '.next.fired_run_id' | sed 's/^$/not yet started/')" ;;
    running|routing) hint="running \`$(S .current.role)\` since $(S .current.started_at)" ;;
    evidence) hint="waiting for evidence \`$(S .evidence.pending.workflow)\` on $(S .evidence.pending.head | cut -c1-7)" ;;
    done) hint="done" ;;
    dropped) hint="dropped" ;;
    *) hint="$st" ;;
  esac
  url=""
  if [ -n "$(S .current.run_id)" ] && [ "$(S .current.run_id)" != 0 ]; then url=" · $(run_url_of "$(S .current.run_id)")"
  elif [ -n "$(S .next.fired_run_id)" ]; then url=" · $(run_url_of "$(S .next.fired_run_id)")"; fi
  printf '`%s` · `%s` · next: %s · $%s · %s min (+%s)%s\n' "$stage" "$st" "$hint" "$cost" "${rm:-0}" "${om:-0}" "$url"
}

# ── brakes before a fire (G6, G7, G30, G31) ───────────────────────────────

envelope_minutes() { case ${1:-full} in short) echo 175 ;; *) echo 300 ;; esac; }
envelope_usd() { case ${1:-full} in short) echo 15 ;; *) echo 45 ;; esac; }

# monthly_brake <path> → prints "<used>/<limit> min" (or usd) when the brake is on; exit 0 = on
monthly_brake() {
  local path=$1 limit used usd_limit usd env_m env_u totals
  limit=$(C '.limits.runner_minutes_month'); usd_limit=$(C '.limits.usd_month')
  env_m=$(envelope_minutes "$path"); env_u=$(envelope_usd "$path")
  totals=$("$SWARM_LIB/state.sh" month-totals "$REPO" 2>/dev/null) || totals='{}'
  used=$("$SWARM_LIB/state.sh" billing-used "$OWNER" 2>/dev/null)
  [ -n "$used" ] || used=$(printf '%s' "$totals" | jq -r '.minutes // 0')
  usd=$(printf '%s' "$totals" | jq -r '.cost_usd // 0')
  if [ -n "$limit" ] && [ "$limit" != 0 ] && jq -e -n --argjson u "${used:-0}" --argjson e "$env_m" --argjson l "$limit" '$u + $e > $l' >/dev/null 2>&1; then
    printf '%s/%s min this month (+%s estimated for this issue)\n' "$used" "$limit" "$env_m"
    return 0
  fi
  if [ -n "$usd_limit" ] && [ "$usd_limit" != 0 ] && jq -e -n --argjson u "${usd:-0}" --argjson e "$env_u" --argjson l "$usd_limit" '$u + $e > $l' >/dev/null 2>&1; then
    printf '$%s/$%s this month (+$%s estimated for this issue)\n' "$usd" "$usd_limit" "$env_u"
    return 0
  fi
  return 1
}

# gate_budget <summary-kind> <detail>: the cost/monthly wait-state on a queued next (G30/G31)
gate_budget() {
  local kind=$1 detail=$2 cap cost approver body cid est new_cap
  write gate-enter --arg name budget --arg note "$kind: $detail" >/dev/null || { log "resolve: gate-enter budget refused (state moved on)"; say "$kind: $detail"; }
  cap=$(S '.limits.cost_usd_per_issue'); [ -n "$cap" ] || cap=$(C '.limits.cost_usd_per_issue')
  cost=$(jq -r '((.totals.cost_usd // 0) * 100 | round / 100)' "$STATE")
  approver=$(approvers_for default | head -1); [ -n "$approver" ] || approver=$OWNER
  est=$(case $(role_entry "$(S .next.stage)" "$(S .next.role)" | jq -r '.tier // "default"') in cheap) echo 0.10 ;; strong) echo 8 ;; *) echo 4 ;; esac)
  new_cap=$(jq -n --argjson c "${cap:-0}" --argjson e "$(envelope_usd "$(path_of)")" '$c + $e')
  body=$(tmpf .md) || die "resolve: no temp dir"
  "$SWARM_LIB/render.sh" gate-budget "$body" --arg approver "$approver" --arg cost "$cost" --arg cap "${cap:-0}" --arg issue "$ISSUE" \
    --sarg next "$(S .next.role) ($kind: $detail)" --arg estimate "$est" --arg runner_minutes "$(S '.totals.runner_minutes' | sed 's/^$/0/')" \
    --arg overhead_minutes "$(S '.totals.overhead_minutes' | sed 's/^$/0/')" --arg new_cap "$new_cap" \
    --arg marker "$(marker gate "gate=budget" "key=$(S .next.key)")" || die "resolve: cannot render the budget gate comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred gate "gate=budget" "key=$(S .next.key)")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "resolve: gate comment not edited"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "resolve: gate comment not posted"
  fi
  [ -n "${cid:-}" ] && write comment-id --arg target gate --arg comment_id "$cid" >/dev/null 2>&1
  rm -f "$body"
  projection
  say "swarm:gate:budget — $kind: $detail"
}

# brakes <stage> <role> <reason>: run before every fire; returns only when the fire may go on
brakes() {
  local stage=$1 role=$2 reason=$3 limit n spent budget cbudget cap cost cls brake
  limit=$(C '.limits.runaway_per_hour'); [ -n "$limit" ] || limit=10
  n=$(jq -r --arg now "$(now)" '[(.dispatches // [])[] | select(((.at // "1970-01-01T00:00:00Z") | fromdateiso8601) >= (($now | fromdateiso8601) - 3600))] | length' "$STATE")
  if [ "$n" -ge "$limit" ]; then
    say "runaway: $n dispatches in the last hour (limit $limit)" runaway
  fi
  if [ "$reason" = rework ]; then
    spent=$(S '.rework.spent'); budget=$(S '.rework.budget'); cbudget=$(C '.limits.rework_budget')
    [ -n "$budget" ] || budget=${cbudget:-5}
    if [ -n "$cbudget" ] && [ "$cbudget" -lt "$budget" ]; then budget=$cbudget; fi
    if [ "${spent:-0}" -gt "$budget" ]; then
      say "rework budget exhausted (${spent}/${budget}); /swarm reject or /swarm redo resets it" budget
    fi
  fi
  cap=$(S '.limits.cost_usd_per_issue'); [ -n "$cap" ] || cap=$(C '.limits.cost_usd_per_issue')
  cost=$(S '.totals.cost_usd'); cost=${cost:-0}
  if [ -n "$cap" ] && [ "$cap" != 0 ] && jq -e -n --argjson c "$cost" --argjson cap "$cap" '$c >= $cap' >/dev/null 2>&1 && [ "$(status)" = queued ]; then
    gate_budget "cost cap" "\$$cost of \$$cap spent"
  fi
  cls=$(role_class "$stage" "$role")
  if [ "$cls" = write ] && [ "$(status)" = queued ] && brake=$(monthly_brake "$(path_of)"); then
    gate_budget "monthly budget" "$brake"
  fi
  return 0
}

# fire_next <reason>: fire state.next through fire.sh (claim, verify, blocked:fire on failure)
fire_next() {
  local reason=$1 stage role key rc=0
  stage=$(S .next.stage); role=$(S .next.role); key=$(S .next.key)
  [ -n "$key" ] || { log "resolve: nothing queued to fire"; return 0; }
  brakes "$stage" "$role" "$(S '.next.reason' | sed 's/^$/chain/')"
  "$SWARM_LIB/fire.sh" "$ISSUE" "$stage" "$role" "$key" "$reason" >/dev/null || rc=$?
  if [ $rc -ne 0 ]; then
    out go false; out reason "fire of $key failed"; out block ""
    exit 1
  fi
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || true
  log "resolve: fired $key ($reason)"
  return 0
}

# fire_finalize: the stub with reason=finalize for current.key (no claim — the dispatch is current, not next)
fire_finalize() {
  local stub default key err
  stub=$(stub_file) || die "resolve: the stub file is unknown"
  default=$(default_branch) || die "resolve: the default branch is unknown"
  key=$(S .current.key)
  err=$(tmpf .err) || die "resolve: no temp dir"
  if gh workflow run -R "$REPO" "$stub" --ref "$default" -f issue="$ISSUE" -f stage="$(S .stage)" -f role="$(S .current.role)" -f key="$key" -f reason=finalize >/dev/null 2> "$err"; then
    rm -f "$err"
    log "resolve: finalize fired for $key"
    return 0
  fi
  log "resolve: finalize fire failed: $(tail -n 1 "$err")"
  rm -f "$err"
  return 1
}

# ── the claim (chain/resume/redo/retry/watchdog/evidence/manual dispatches) ───

emit_role_outputs() { # <stage> <role[:lane]> <key>
  local stage=$1 role=$2 key=$3 base lane e cls tier model rtier rmodel critic cmodel crubric cthr cturns ctimeout turns timeout rtimeout retry jobt protected deny wroots allowed disallowed evidence_json head
  base=${role%%:*}; lane=""; [ "$base" != "$role" ] && lane=${role#*:}
  e=$(role_entry "$stage" "$role")
  cls=$(printf '%s' "$e" | jq -r '.class // "read"')
  tier=$(printf '%s' "$e" | jq -r '.tier // "default"')
  model=$(model_for_tier "$tier")
  rtier=$(P ".models.retry_tier_for[\"$tier\"]"); [ -n "$rtier" ] || rtier=$tier
  rmodel=$(model_for_tier "$rtier")
  turns=$(printf '%s' "$e" | jq -r '.turns // 60'); timeout=$(printf '%s' "$e" | jq -r '.timeout // 20')
  rtimeout=$(( timeout < 20 ? timeout : 20 ))
  retry=$(printf '%s' "$e" | jq -r 'if .retry == false then "false" else "true" end')
  cturns=$(P '.critic_defaults.turns'); [ -n "$cturns" ] || cturns=40
  ctimeout=$(P '.critic_defaults.timeout'); [ -n "$ctimeout" ] || ctimeout=15
  critic=$(printf '%s' "$e" | jq -c --arg path "$(path_of)" '.critic // "none" | if type != "object" then null elif (.enabled == false) then null elif ($path == "short" and (.on_short // "run") == "skip") then null else . end')
  cmodel=""; crubric=""; cthr=""
  if [ "$critic" != null ] && [ -n "$critic" ]; then
    local ctier
    ctier=$(printf '%s' "$critic" | jq -r '.tier // empty'); [ -n "$ctier" ] || ctier=$(P ".models.critic_tier_for[\"$tier\"]"); [ -n "$ctier" ] || ctier=default
    cmodel=$(model_for_tier "$ctier"); crubric=$(printf '%s' "$critic" | jq -r '.rubric // "generic"'); cthr=$(printf '%s' "$critic" | jq -r '.threshold // 65')
  fi
  jobt=$(( timeout + rtimeout + 10 ))
  if [ "$cls" != write ] && [ -n "$cmodel" ]; then jobt=$(( jobt + ctimeout )); fi
  allowed=$(P ".classes[\"$cls\"].allowed"); disallowed=$(P ".classes[\"$cls\"].disallowed")
  wroots=$(jq -r --arg c "$cls" '.classes[$c].write_roots // [] | join(":")' "$PIPELINE")
  protected=$(jq -r -n --argjson a "$(jq -c '.protected_paths // []' "$PIPELINE")" --argjson b "$(jq -c '.protected_paths // []' "$CONFIG_JSON")" '($a + $b) | map(select(. != ".swarm-run/**")) | unique | join(":")')
  deny=$(jq -r '.deny_paths // [] | join(":")' "$PIPELINE")
  head=$(S .head)
  evidence_json=$(jq -c --arg h "$head" '
    (if .pr != null then "pull_request" else "push" end) as $ev
    | ((.evidence.seen // {})[$h] // {}) | to_entries
    | map({key: .key, value: ((.value[$ev] // .value.workflow_dispatch // (.value | to_entries | sort_by(.value.at) | last | .value) // null)
                              | if . == null then null else {run_id: .run_id, conclusion: .conclusion, head: $h, url: (.url // null)} end)})
    | map(select(.value != null)) | from_entries' "$STATE")
  out issue "$ISSUE"; out stage "$stage"; out role "$role"; out lane "$lane"; out class "$cls"
  out attempt "${key##*:}"; out key "$key"
  out model "$model"; out retry_model "$rmodel"; out critic_model "$cmodel"; out critic_rubric "$crubric"; out critic_threshold "$cthr"
  out max_turns "$turns"; out timeout "$timeout"; out retry_timeout "$rtimeout"; out retry_allowed "$retry"
  out critic_turns "$cturns"; out critic_timeout "$ctimeout"; out job_timeout "$jobt"
  out allowed_tools "$allowed"; out disallowed_tools "$disallowed"; out write_roots "$wroots"; out protected "$protected"; out deny "$deny"
  out branch "$(branch_name)"; out head "$head"; out pr "$(S .pr)"; out path "$(path_of)"; out swarm_sha "$(S .swarm_sha)"
  out base_sha "$(S .current.base_sha)"; out evidence_json "$evidence_json"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'STATE_JSON=%s\nCONFIG_JSON=%s\nISSUE=%s\nSTAGE=%s\nROLE=%s\nLANE=%s\nATTEMPT=%s\nKEY=%s\n' \
      "$STATE" "$CONFIG_JSON" "$ISSUE" "$stage" "$role" "$lane" "${key##*:}" "$key" >> "$GITHUB_ENV"
  fi
}

branch_name() { # state.branch, else <prefix><N>-<slug(title)>
  local b
  b=$(S .branch)
  [ -n "$b" ] && { printf '%s\n' "$b"; return; }
  printf '%s%s-%s\n' "$(C .branch_prefix | sed 's/^$/claude\/issue-/')" "$ISSUE" "$(printf '%s' "$ISSUE_TITLE" | slugify)"
}

claim() { # <reason>
  local reason=$1 key stage role base lane winner base_sha model emoji body cid attempt
  [ $HAVE_STATE -eq 1 ] || say "no state for #$ISSUE — a dispatch without a state file runs nothing"
  case $(status) in
    dropped|done) say "#$ISSUE is $(status); nothing runs" ;;
  esac
  # G8
  base=${D_ROLE%%:*}; lane=""; [ "$base" != "$D_ROLE" ] && lane=${D_ROLE#*:}
  if [ -n "$D_STAGE" ] && ! stage_known "$D_STAGE"; then say "unknown stage '$D_STAGE'" bad-handoff; fi
  if [ -n "$D_ROLE" ] && { [ -z "$D_STAGE" ] || [ -z "$(role_entry "$D_STAGE" "$D_ROLE")" ]; }; then say "unknown role '$D_ROLE' for stage '$D_STAGE'" bad-handoff; fi
  if ! lane_known "$lane"; then say "unknown lane '$lane' (not in .github/swarm.yml lanes)" bad-handoff; fi
  # G16
  key=$(S .next.key); stage=$(S .next.stage); role=$(S .next.role)
  if [ "$(status)" != queued ] || [ -z "$key" ]; then
    winner=$(S .current.run_id)
    if [ "$(S .current.key)" = "$D_KEY" ] && [ -n "$winner" ]; then say "key $D_KEY is held by run $winner (status $(status)) — nothing to claim"; fi
    say "status is $(status), not queued — key $D_KEY not claimable"
  fi
  [ "$key" = "$D_KEY" ] || say "key mismatch: dispatched $D_KEY, state.next is $key — a late or duplicate fire"
  if [ -n "$D_STAGE" ] && [ "$D_STAGE" != "$stage" ]; then say "stage mismatch: dispatched $D_STAGE, state.next is $stage"; fi
  if [ -n "$D_ROLE" ] && [ "$D_ROLE" != "$role" ]; then say "role mismatch: dispatched $D_ROLE, state.next is $role"; fi
  winner=$(S .next.fired_run_id)
  if [ -n "$winner" ] && [ "$winner" != "$RUN_ID" ]; then say "key $key was fired as run $winner; this run ($RUN_ID) is not it"; fi
  if [ -n "$(S .next.not_before)" ] && jq -e --arg now "$(now)" '(.next.not_before | fromdateiso8601) > ($now | fromdateiso8601)' "$STATE" >/dev/null; then
    say "key $key is not to run before $(S .next.not_before)"
  fi
  brakes "$stage" "$role" "$(S '.next.reason' | sed 's/^$/chain/')"
  base_sha=$(gh api "repos/$REPO/git/ref/heads/$(branch_name)" --jq '.object.sha // empty' 2>/dev/null) || base_sha=""
  [ -n "$base_sha" ] || base_sha=$(S .head)
  model=$(role_model "$stage" "$role")
  local rc=0
  write dispatch-running --arg key "$key" --arg run_id "$RUN_ID" --arg run_attempt "$RUN_ATTEMPT" --arg base_sha "$base_sha" --arg model "$model" >/dev/null || rc=$?
  case $rc in
    0) ;;
    5) "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null; say "claim of $key lost — held by run $(S .current.run_id) (status $(status))" ;;
    *) die "resolve: the claim of $key failed (state.sh exit $rc)" ;;
  esac
  attempt=${key##*:}
  emoji=$(P ".emoji[\"${role%%:*}\"]"); [ -n "$emoji" ] || emoji="🧭"
  body=$(tmpf .md) || die "resolve: no temp dir"
  "$SWARM_LIB/render.sh" working "$body" --arg emoji "$emoji" --arg role "$role" --arg attempt "$attempt" --arg started_at "$(now)" --arg run_url "$RUN_URL" \
    --arg marker "$(marker stage "stage=$stage" "role=$role" "attempt=$attempt" "key=$key" "run=$RUN_ID" "status=running")" || die "resolve: cannot render the working comment"
  if existing=$(find_comment "$ISSUE" "$(marker_pred stage "key=$key" "run=$RUN_ID")"); then
    cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || log "resolve: working comment not edited"
  else
    cid=$(post_comment "$ISSUE" "$body") || log "resolve: working comment not posted"
  fi
  rm -f "$body"
  [ -n "${cid:-}" ] && write comment-id --arg target current --arg comment_id "$cid" --arg key "$key" >/dev/null 2>&1
  projection
  emit_role_outputs "$stage" "$role" "$key"
  out working_comment_id "${cid:-}"
  out finalize false
  out block ""
  out reason "claimed $key ($reason)"
  out go true
  log "resolve: claimed $key as run $RUN_ID ($reason)"
  exit 0
}

# ── evidence consumption (workflow_run, resume at evidence, watchdog) ───────

consume_pending() { # <conclusion> <run_id> [<log-source-run-id>]: fire the pending consumer (G23 first)
  local concl=$1 rid=$2 consumer base lane stage key repro rc=0 req
  consumer=$(S .evidence.pending.consumer); key=$(S .evidence.pending.key); stage=$(S .stage)
  base=${consumer%%:*}; lane=""; [ "$base" != "$consumer" ] && lane=${consumer#*:}
  req=$(role_entry "$stage" "$consumer" | jq -r '.requires_ci // empty')
  # G23 reads the CI conclusion only; a failed test/security workflow still runs its role (on_failure: run_role)
  if [ "$(S .evidence.pending.workflow)" = ci ] && [ "$req" = success ] && [ "$concl" != success ]; then
    [ -n "$lane" ] || lane=$(first_lane)
    repro=$(gh run view -R "$REPO" "${3:-$rid}" --log-failed 2>/dev/null | tail -n 120 | redact)
    [ -n "$repro" ] || repro="CI concluded $concl on $(S .evidence.pending.head | cut -c1-7) (run $rid); no failed-job log was available"
    write rework --arg from ci-red --arg to "dev:$lane" --arg stage build --arg reason "$repro" --arg from_key "$key" >/dev/null || rc=$?
    if [ $rc -eq 5 ]; then say "rework budget exhausted — CI red on $(S .evidence.pending.head | cut -c1-7) cannot be sent back to dev:$lane" budget; fi
    [ $rc -eq 0 ] || die "resolve: cannot record the CI-red rework (state.sh exit $rc)"
    log "resolve: CI $concl on head — rework dev:$lane with the failed-job log (G23)"
    projection
    fire_next rework
    return 0
  fi
  write dispatch-queued --arg stage "$stage" --arg role "$consumer" --arg from_key "$key" --arg reason evidence >/dev/null || rc=$?
  [ $rc -eq 0 ] || say "the pending wait moved on before $consumer could be queued (state.sh exit $rc)"
  projection
  fire_next evidence
}

# requery_pending: ask GitHub about the pending run (§4.5); 0 = complete and consumed
requery_pending() {
  local slot head consumer o st concl rid
  slot=$(S .evidence.pending.workflow); head=$(S .evidence.pending.head); consumer=$(S .evidence.pending.consumer)
  o=$(tmpf .ev) || die "resolve: no temp dir"
  ( GITHUB_OUTPUT=$o ISSUE=$ISSUE "$SWARM_LIB/evidence.sh" wait "$slot" "$head" "$consumer" ) >/dev/null 2>&1 || true
  st=$(sed -n 's/^evidence_status=//p' "$o" | tail -1); concl=$(sed -n 's/^evidence_conclusion=//p' "$o" | tail -1); rid=$(sed -n 's/^evidence_run_id=//p' "$o" | tail -1)
  rm -f "$o"
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
  if [ "$st" = complete ]; then
    [ "$(status)" = evidence ] || write resume --arg mode evidence >/dev/null 2>&1 || true
    consume_pending "$concl" "$rid"
    return 0
  fi
  return 1
}

# ── human commands (§6.3) ─────────────────────────────────────────────────

need_gate_status() { [ "$(status)" = gate ] || refuse_human "not at a gate — $(status_line)"; }

verify_approvers_note() { # every configured login must be a User (recorded in the log)
  local l t note=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    t=$(owner_type "$l" 2>/dev/null) || t="unknown"
    note+="$l:$t "
  done < <(jq -r '[.approvers // {} | .[]?[]] | unique | .[]' "$CONFIG_JSON")
  printf '%s\n' "${note:-owner:$(owner_type "$OWNER" 2>/dev/null || echo unknown)}"
}

open_swarm_prs() {
  gh pr list -R "$REPO" --state open --json headRefName --limit 100 --jq "[.[] | select(.headRefName | startswith(\"$(C .branch_prefix)\"))] | length" 2>/dev/null || echo 0
}

do_start() {
  local path force limit n note sha psha stage role model doc branch rc list
  path=$(printf '%s' "$CMD" | jq -r '.path // empty'); force=$(printf '%s' "$CMD" | jq -r '.force // false')
  if [ $HAVE_STATE -eq 1 ]; then
    case $(status) in
      done) refuse_human "#$ISSUE finished — merged $(S .merged_at) (PR #$(S .merged_pr)); use \`/swarm redo <stage>\` to run a stage again" ;;
      queued)
        if jq -e --arg now "$(now)" '((($now | fromdateiso8601) - (.created_at | fromdateiso8601)) < 300)' "$STATE" >/dev/null; then
          refuse_human "already started at $(S .created_at) — $(S .next.key) is queued"
        fi
        refuse_human "already started — $(status_line)" ;;
      parked|blocked|dropped)
        log "resolve: start on a $(status) issue behaves as resume"
        CMD='{"verb":"resume","args":""}'; VERB=resume
        do_resume ;;
      *) refuse_human "already started — $(status_line)" ;;
    esac
  fi
  list=$(approvers_for default) || refuse_human "this repository is owned by an organisation and .github/swarm.yml names no approvers — configure approvers in .github/swarm.yml"
  if [ "$force" != true ] && brake=$(monthly_brake "${path:-full}"); then
    refuse_human "monthly budget: $brake; \`/swarm start force\` to override"
  fi
  limit=$(C '.limits.open_prs'); n=$(open_swarm_prs)
  if [ -n "$limit" ] && [ "$limit" != 0 ] && [ "${n:-0}" -ge "$limit" ]; then
    refuse_human "$n open swarm pull requests (limit $limit) — merge or close one, then \`/swarm start\` again"
  fi
  note="approvers: $(verify_approvers_note)"
  local v1=false
  if gh_json --paginate "repos/$REPO/issues/$ISSUE/comments" 2>/dev/null | jq -e 'any(.[]?; .body | contains("swarm: v1"))' >/dev/null 2>&1; then v1=true; fi
  sha=$(git -C "$SWARM_ROOT" rev-parse HEAD 2>/dev/null) || sha=${SWARM_SHA:-}
  psha=$(git hash-object "$PIPELINE" 2>/dev/null) || psha=""
  if [ -n "$path" ]; then stage=requirements; role=analyst; else stage=triage; role=triage; fi
  model=$(role_model "$stage" "$role")
  doc=$(tmpf .doc) || die "resolve: no temp dir"
  local -a args=(--arg issue "$ISSUE" --arg repo "$REPO" --arg by "$SENDER" --arg stage "$stage" --arg role "$role"
                 --arg swarm_sha "$sha" --arg pipeline_sha "$psha" --arg config_sha "$(C .config_sha)"
                 --arg budget "$(C '.limits.rework_budget' | sed 's/^$/5/')" --arg question_rounds "$(C '.limits.question_rounds' | sed 's/^$/2/')"
                 --arg v1_history "$v1" --arg model "$model" --arg note "$note")
  [ -n "$path" ] && args+=(--arg path "$path" --arg path_source owner)
  "$SWARM_LIB/state.sh" apply null start "${args[@]}" > "$doc" || die "resolve: cannot build the initial state"
  branch=$(branch_name)
  jq --arg b "$branch" '.branch = $b' "$doc" > "$doc.b" && mv -f "$doc.b" "$doc"
  rc=0
  "$SWARM_LIB/state.sh" create "$ISSUE" "$doc" > "$STATE" 2>/dev/null || rc=$?
  case $rc in
    0) HAVE_STATE=1 ;;
    7) HAVE_STATE=1; rm -f "$doc"; refuse_human "already started by a concurrent start (state exists: $(S .next.key // .status))" ;;
    6) rm -f "$doc"; say "state #$ISSUE exists with an invalid signature" perimeter ;;
    *) rm -f "$doc"; die "resolve: cannot create the state of #$ISSUE (state.sh exit $rc)" ;;
  esac
  rm -f "$doc"
  if printf '%s\n' "$ISSUE_LABELS" | grep -qxF swarm:ready; then
    gh api -X DELETE "repos/$REPO/issues/$ISSUE/labels/swarm:ready" >/dev/null 2>&1 || log "resolve: swarm:ready not removed"
  fi
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "resolve: state comment not posted"
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
  "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" >/dev/null || log "resolve: labels.sh project failed"
  ack "started (${path:-full} path$( [ "$v1" = true ] && printf ', v1 comments kept as data')) — \`$role\` queued as \`$(S .next.key)\` on branch \`$branch\`"
  fire_next chain
  ok_done "started #$ISSUE: fired $(S '.next.key // .current.key')"
}

do_approve() {
  local g want ns role cap new_cap
  need_gate_status
  g=$(S .gate.name); want=$(printf '%s' "$CMD" | jq -r '.gate // empty')
  if [ -n "$want" ] && [ "$want" != "$g" ]; then
    [ "$want" = release ] && refuse_human "\`approve release\` is not a command — gate 3 is the merge of the PR by an approver (the issue is at gate \`$g\`)"
    refuse_human "the open gate is \`$g\`, not \`$want\`"
  fi
  case $g in
    release) refuse_human "\`approve release\` is not a command — merge PR #$(S .pr) (the merge must be made by $(approvers_for release | tr '\n' ' ' | sed 's/ $//'))" ;;
    question) refuse_human "at the question gate: answer in plain text, or \`/swarm resume\` to proceed on the stated assumptions" ;;
  esac
  is_approver "$SENDER" "$g" || refuse_human "only $(approvers_for "$g" | tr '\n' ' ' | sed 's/ $//') may approve the \`$g\` gate"
  if [ "$g" = budget ]; then
    cap=$(S '.limits.cost_usd_per_issue'); [ -n "$cap" ] || cap=$(C '.limits.cost_usd_per_issue')
    new_cap=$(jq -n --argjson c "${cap:-0}" --argjson e "$(envelope_usd "$(path_of)")" '$c + $e')
    write gate-approve --arg name budget --arg by "$SENDER" --arg cap "$new_cap" >/dev/null || refuse_human "the budget gate moved on — $(status_line)"
    projection
    ack "approved by $SENDER — cap raised to \$$new_cap; \`$(S .next.key)\` fires"
    fire_next resume
    ok_done "budget gate approved; fired $(S '.next.key // .current.key')"
  fi
  ns=$(next_stage_after "$(S .stage)")
  [ -n "$ns" ] || refuse_human "nothing follows \`$(S .stage)\` on the $(path_of) path"
  role=$(first_role "$ns")
  [ -n "$role" ] || refuse_human "stage \`$ns\` has no role on the $(path_of) path"
  local -a a=(--arg name "$g" --arg by "$SENDER" --arg stage "$ns" --arg role "$role")
  [ -n "$COMMENT_ID" ] && a+=(--arg comment_id "$COMMENT_ID")
  write gate-approve "${a[@]}" >/dev/null || refuse_human "the gate moved on — $(status_line)"
  projection
  ack "approved by $SENDER — \`$role\` queued as \`$(S .next.key)\`"
  fire_next resume
  ok_done "gate $g approved; fired $(S '.next.key // .current.key')"
}

do_reject() {
  local g why stage role
  need_gate_status
  g=$(S .gate.name); why=$(printf '%s' "$CMD" | jq -r '.reason')
  is_approver "$SENDER" "$g" || refuse_human "only $(approvers_for "$g" | tr '\n' ' ' | sed 's/ $//') may reject at the \`$g\` gate"
  case $g in
    requirements|question) stage=requirements; role=analyst ;;
    architecture) stage=architecture; role=architect ;;
    confidence) stage=$(S .stage); role=$(S .gate.escalated_role); [ -n "$role" ] || role=$(first_role "$stage") ;;
    release) stage=release; role=analyst ;;
    budget) stage=""; role="" ;;
    *) refuse_human "unknown gate \`$g\`" ;;
  esac
  local -a a=(--arg name "$g" --arg by "$SENDER" --arg reason "$why")
  [ -n "$stage" ] && a+=(--arg stage "$stage" --arg role "$role")
  write gate-reject "${a[@]}" >/dev/null || refuse_human "the gate moved on — $(status_line)"
  projection
  if [ "$g" = budget ]; then
    ack "rejected by $SENDER — parked; \`/swarm resume\` continues, \`/swarm drop\` abandons"
    ok_done "budget gate rejected; parked"
  fi
  ack "rejected by $SENDER — \`$role\` re-runs as \`$(S .next.key)\` with your reason (budget reset)"
  fire_next resume
  ok_done "gate $g rejected; fired $(S '.next.key // .current.key')"
}

run_alive() { # <run_id>
  local st
  st=$(gh run view -R "$REPO" "$1" --json status --jq .status 2>/dev/null) || st=""
  case $st in in_progress|queued|waiting|pending|requested) return 0 ;; esac
  return 1
}

run_job_completed() { # <run_id>: the run job (run-read / run-write) completed
  gh run view -R "$REPO" "$1" --json jobs --jq '[.jobs[]? | select(.name | test("^run-(read|write)")) | select(.status == "completed") | select(.conclusion | IN("success", "failure"))] | length' 2>/dev/null \
    | grep -qE '^[1-9]'
}

handoff_exists() { # <run_id> <key> — artifact names carry the key with ':' mapped to '-'
  local k=${2//:/-}
  gh api "repos/$REPO/actions/runs/$1/artifacts" --jq "[.artifacts[]? | select(.name == \"swarm-run-$k-$1\") | select(.expired != true)] | length" 2>/dev/null | grep -qE '^[1-9]'
}

do_resume() {
  local st reason
  st=$(status)
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  case $st in
    blocked)
      reason=$(S .blocked.reason)
      case $reason in
        fire)
          if [ -n "$(S .next.key)" ]; then
            write resume --arg mode next --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
            projection; ack "resumed by $SENDER — re-firing \`$(S .next.key)\`"; fire_next resume; ok_done "re-fired $(S '.next.key // .current.key')"
          elif [ -n "$(S .evidence.pending.key)" ]; then
            write resume --arg mode evidence --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
            projection; ack "resumed by $SENDER — re-firing the \`$(S .evidence.pending.workflow)\` evidence workflow"
            "$SWARM_LIB/evidence.sh" fire "$ISSUE" "$(S .evidence.pending.workflow)" "$(S .evidence.pending.head)" "$(S .evidence.pending.key)" "$(S .evidence.pending.consumer)" >/dev/null || exit 1
            ok_done "evidence re-fired"
          fi ;;
        stalled)
          if [ -n "$(S .current.run_id)" ] && run_job_completed "$(S .current.run_id)" && handoff_exists "$(S .current.run_id)" "$(S .current.key)"; then
            write resume --arg mode finalize --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
            projection
            if fire_finalize; then
              ack "resumed by $SENDER — finalising run $(S .current.run_id) from its handoff (reason=finalize)"
              ok_done "finalize fired for $(S .current.key)"
            fi
            die "resolve: the finalize fire failed; \`/swarm resume\` again"
          fi ;;
        evidence)
          if [ -n "$(S .evidence.pending.key)" ]; then
            write resume --arg mode evidence --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
            projection
            if requery_pending; then ok_done "evidence consumed"; fi
            ack "resumed by $SENDER — still waiting for \`$(S .evidence.pending.workflow)\` on $(S .evidence.pending.head | cut -c1-7)"
            ok_done "evidence still pending"
          fi ;;
      esac
      [ -n "$(S .current.role)" ] || refuse_human "nothing to retry — $(status_line)"
      write resume --arg mode retry --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
      projection; ack "resumed by $SENDER — \`$(S .next.role)\` re-runs as \`$(S .next.key)\`"; fire_next resume
      ok_done "retry fired $(S '.next.key // .current.key')" ;;
    parked)
      if [ -n "$(S .next.key)" ]; then
        write resume --arg mode next --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
        projection; ack "resumed by $SENDER — firing \`$(S .next.key)\`"; fire_next resume; ok_done "fired $(S '.next.key // .current.key')"
      fi
      [ -n "$(S .current.role)" ] || refuse_human "nothing to resume — $(status_line)"
      write resume --arg mode retry --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
      projection; ack "resumed by $SENDER — \`$(S .next.role)\` re-runs as \`$(S .next.key)\`"; fire_next resume
      ok_done "retry fired $(S '.next.key // .current.key')" ;;
    queued)
      local rm fired rid
      rm=$(C '.watchdog.queued_refire_minutes'); [ -n "$rm" ] || rm=30
      fired=$(S .next.fired_at); rid=$(S .next.fired_run_id)
      if [ -n "$fired" ] && jq -e --arg now "$(now)" --argjson m "$rm" '((($now | fromdateiso8601) - (.next.fired_at | fromdateiso8601)) < ($m * 60))' "$STATE" >/dev/null \
         && [ -n "$rid" ] && run_alive "$rid"; then
        refuse_human "already fired: $(run_url_of "$rid") (started $fired)"
      fi
      write resume --arg mode next --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
      projection; ack "resumed by $SENDER — re-firing \`$(S .next.key)\`"; fire_next resume; ok_done "re-fired $(S '.next.key // .current.key')" ;;
    evidence)
      if requery_pending; then ok_done "evidence consumed"; fi
      ack "still waiting for \`$(S .evidence.pending.workflow)\` on $(S .evidence.pending.head | cut -c1-7) (run $(S .evidence.pending.run_id))"
      ok_done "evidence still pending" ;;
    gate)
      [ "$(S .gate.name)" = question ] || refuse_human "not resumable at the \`$(S .gate.name)\` gate — $(status_line)"
      write resume --arg mode question --arg by "$SENDER" >/dev/null || refuse_human "cannot resume — $(status_line)"
      projection; ack "resumed by $SENDER — the analyst proceeds on its stated assumptions as \`$(S .next.key)\`"; fire_next resume
      ok_done "question gate resumed; fired $(S '.next.key // .current.key')" ;;
    *) refuse_human "nothing to resume — $(status_line)" ;;
  esac
}

do_redo() {
  local stage why role sha
  stage=$(printf '%s' "$CMD" | jq -r '.stage'); why=$(printf '%s' "$CMD" | jq -r '.reason // ""')
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  case $(status) in running|routing) refuse_human "wait for the stage to finish or \`/swarm park\` first — $(status_line)" ;; esac
  [ "$stage" != retro ] || refuse_human "retro runs after the merge, not on demand"
  stage_on_path "$stage" || refuse_human "\`$stage\` is not on the $(path_of) path"
  [ -z "$(S .merged_at)" ] || refuse_human "#$ISSUE is merged ($(S .merged_at)); nothing can be redone"
  role=$(first_role "$stage")
  sha=$(git -C "$SWARM_ROOT" rev-parse "origin/$SWARM_REF" 2>/dev/null) || sha=$(git -C "$SWARM_ROOT" rev-parse HEAD 2>/dev/null) || sha=$(S .swarm_sha)
  local -a a=(--arg stage "$stage" --arg role "$role" --arg by "$SENDER" --arg reason "$why")
  [ -n "$sha" ] && a+=(--arg swarm_sha "$sha")
  write redo "${a[@]}" >/dev/null || refuse_human "cannot redo — $(status_line)"
  log "resolve: swarm code re-pinned at ${sha:-unchanged} for the redo"
  pin_checkout
  projection
  ack "redo \`$stage\` by $SENDER — \`$role\` queued as \`$(S .next.key)\` (budget reset, swarm re-pinned at ${sha:0:7})"
  fire_next redo
  ok_done "redo $stage; fired $(S '.next.key // .current.key')"
}

do_skip() {
  local stage why gate ns role
  stage=$(printf '%s' "$CMD" | jq -r '.stage'); why=$(printf '%s' "$CMD" | jq -r '.reason // ""')
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  case $(status) in running|routing) refuse_human "wait for the stage to finish or \`/swarm park\` first — $(status_line)" ;; esac
  case $stage in triage|build|release|retro) refuse_human "\`$stage\` cannot be skipped" ;; esac
  stage_on_path "$stage" || refuse_human "\`$stage\` is not on the $(path_of) path"
  local -a a=(--arg stage "$stage" --arg by "$SENDER" --arg reason "$why")
  if [ "$stage" = "$(S .stage)" ]; then
    gate=$(stage_gate "$stage")
    if [ -n "$gate" ] && ! { [ "$(status)" = gate ] && [ "$(S .gate.name)" = "$gate" ]; }; then
      a+=(--arg gate "$gate")
      write skip "${a[@]}" >/dev/null || refuse_human "cannot skip — $(status_line)"
      local body cid approver
      approver=$(approvers_for "$gate" | head -1); [ -n "$approver" ] || approver=$OWNER
      body=$(tmpf .md) || die "resolve: no temp dir"
      "$SWARM_LIB/render.sh" gate "$body" --arg gate "$gate" --arg approver "$approver" \
        --sarg summary "Stage \`$stage\` was skipped by $SENDER${why:+: $why}. The gate after it is still yours to pass." \
        --arg cost "$(jq -r '((.totals.cost_usd // 0) * 100 | round / 100)' "$STATE")" --arg runner_minutes "$(S '.totals.runner_minutes' | sed 's/^$/0/')" \
        --arg instruction "Reply \`/swarm approve\` to continue, or \`/swarm reject <why>\` to run the stage after all." \
        --arg marker "$(marker gate "gate=$gate" "key=skip:$stage")" || die "resolve: cannot render the gate comment"
      cid=$(post_comment "$ISSUE" "$body") || log "resolve: gate comment not posted"
      rm -f "$body"
      [ -n "${cid:-}" ] && write comment-id --arg target gate --arg comment_id "$cid" >/dev/null 2>&1
      projection
      ack "skipped \`$stage\` by $SENDER — the \`$gate\` gate is open: \`/swarm approve\` or \`/swarm reject <why>\`"
      ok_done "skipped $stage; gate $gate"
    fi
    ns=$(next_stage_after "$stage")
    [ -n "$ns" ] || refuse_human "nothing follows \`$stage\` on the $(path_of) path"
    role=$(first_role "$ns")
    a+=(--arg next_stage "$ns" --arg next_role "$role")
    write skip "${a[@]}" >/dev/null || refuse_human "cannot skip — $(status_line)"
    projection
    ack "skipped \`$stage\` by $SENDER — \`$role\` queued as \`$(S .next.key)\`"
    fire_next resume
    ok_done "skipped $stage; fired $(S '.next.key // .current.key')"
  fi
  local idx cur
  idx=$(jq -n --arg s "$stage" '["triage","requirements","design","architecture","build","test","security","release","retro"] | index($s)')
  cur=$(jq -n --arg s "$(S .stage)" '["triage","requirements","design","architecture","build","test","security","release","retro"] | index($s)')
  [ "$idx" -ge "$cur" ] || refuse_human "\`$stage\` is already behind the current stage \`$(S .stage)\`"
  write skip "${a[@]}" >/dev/null || refuse_human "cannot skip — $(status_line)"
  projection
  ack "\`$stage\` will be skipped (by $SENDER)"
  ok_done "skip $stage recorded"
}

do_park() {
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  case $(status) in done|dropped) refuse_human "#$ISSUE is $(status); nothing to park" ;; esac
  local was; was=$(status)
  write park --arg by "$SENDER" >/dev/null || refuse_human "cannot park — $(status_line)"
  projection
  case $was in
    running|routing) ack "parked by $SENDER — the running \`$(S .current.role)\` finishes and is recorded; nothing fires after it; \`/swarm resume\` continues" ;;
    *) ack "parked by $SENDER — \`/swarm resume\` continues" ;;
  esac
  ok_done "parked"
}

do_drop() {
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  [ "$(status)" != dropped ] || refuse_human "#$ISSUE is already dropped"
  write drop --arg by "$SENDER" >/dev/null || refuse_human "cannot drop — $(status_line)"
  projection
  local sub
  while IFS= read -r sub; do
    [ -n "$sub" ] && [ "$sub" != null ] || continue
    gh issue close -R "$REPO" "$sub" --comment "Dropped with #$ISSUE (/swarm drop by $SENDER); nothing was destroyed." >/dev/null 2>&1 || log "resolve: sub-issue #$sub not closed"
  done < <(jq -r '.subissues // {} | to_entries[] | select(.key != "flat") | .value' "$STATE")
  if [ -n "$(S .pr)" ]; then
    reply "$(S .pr)" "$EVENT_ID-pr" "issue #$ISSUE was dropped by $SENDER — this pull request stays open for a human to close or finish; the branch is kept" >/dev/null 2>&1 || true
  fi
  ack "dropped by $SENDER — sub-issues closed, PR and branch kept"
  ok_done "dropped"
}

do_handsoff() {
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  if [ $HAVE_STATE -eq 1 ]; then write hands-off --arg value true --arg by "$SENDER" >/dev/null || true; fi
  printf '{"labels": ["swarm:hands-off"]}' | gh api -X POST "repos/$REPO/issues/$ISSUE/labels" --input - >/dev/null 2>&1 || log "resolve: label not added"
  [ $HAVE_STATE -eq 1 ] && projection
  ack "hands-off by $SENDER — the swarm ignores #$ISSUE until the label is removed by hand (\`/swarm status\` still answers)"
  ok_done "hands-off"
}

do_path() {
  local p ns role
  p=$(printf '%s' "$CMD" | jq -r '.path')
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  [ "$(S .stages.triage.status)" = "done" ] || refuse_human "the path can be set once triage is done — $(status_line)"
  case $(S .stage) in triage|requirements) ;; *) refuse_human "the path can be changed up to the requirements stage; #$ISSUE is at \`$(S .stage)\`" ;; esac
  case $(status) in running|routing) refuse_human "wait for the stage to finish — $(status_line)" ;; esac
  local -a a=(--arg path "$p" --arg source owner --arg by "$SENDER")
  if [ "$(status)" = gate ] && [ "$(S .gate.name)" = requirements ] && [ "$p" = short ]; then
    write path "${a[@]}" >/dev/null || refuse_human "cannot set the path — $(status_line)"
    ns=$(next_stage_after requirements); role=$(first_role "$ns")
    write path "${a[@]}" --arg next_stage "$ns" --arg next_role "$role" >/dev/null || refuse_human "cannot queue \`$ns\` — $(status_line)"
    projection
    ack "path short by $SENDER — the requirements gate is dissolved; \`$role\` queued as \`$(S .next.key)\`"
    fire_next resume
    ok_done "path short; fired $(S '.next.key // .current.key')"
  fi
  write path "${a[@]}" >/dev/null || refuse_human "cannot set the path — $(status_line)"
  projection
  ack "path \`$p\` set by $SENDER (was $(S .path_source))"
  ok_done "path $p"
}

do_status() {
  is_approver "$SENDER" default || refuse_human "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may command the swarm"
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "resolve: state comment not re-rendered"
  ack "$(status_line)"
  ok_done "status"
}

# ── pin ────────────────────────────────────────────────────────────────────

pin_checkout() {
  local sha
  sha=$(S .swarm_sha)
  [ -n "$sha" ] || return 0
  [ -d "$SWARM_ROOT/.git" ] || { log "resolve: swarm tree is not a git checkout — pin $sha not applied"; return 0; }
  if [ -n "${SWARM_FAKE_GH:-}" ]; then log "resolve: pin $sha skipped under the conformance shim"; return 0; fi
  if [ "$(git -C "$SWARM_ROOT" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then return 0; fi
  if git -C "$SWARM_ROOT" checkout -q "$sha" 2>/dev/null; then
    log "resolve: swarm tree pinned at $sha"
  else
    printf '::warning::resolve: swarm_sha %s is not reachable in the checkout; running the %s head instead\n' "$sha" "$SWARM_REF"
  fi
}

# ── 1. intent ──────────────────────────────────────────────────────────────

intent=""
EVENT_ID="run-$RUN_ID"
case $EVENT in
  issues)
    [ "$ACTION" = labeled ] || say "issues.$ACTION is not an event the swarm reads"
    case $LABEL_ADDED in
      swarm:ready) intent=start; is_human=1 ;;
      swarm:hands-off) intent=hands-off-label; is_human=1 ;;
      swarm:*) intent=label-other; is_human=1 ;;
      *) say "label $LABEL_ADDED is not a swarm label" ;;
    esac
    EVENT_ID="label-$RUN_ID" ;;
  issue_comment|pull_request_review)
    if [ "$EVENT" = issue_comment ]; then [ "$ACTION" = created ] || say "issue_comment.$ACTION is not read"; else [ "$ACTION" = submitted ] || say "pull_request_review.$ACTION is not read"; fi
    CMD=$("$SWARM_LIB/commands.sh" parse < "$BODY_FILE")
    VERB=$(printf '%s' "$CMD" | jq -r '.verb // empty')
    [ -n "$COMMENT_ID" ] && EVENT_ID=$COMMENT_ID
    if [ -n "$VERB" ]; then intent="command"; else
      [ "$EVENT" = issue_comment ] || say "a review without a /swarm command is not read"
      intent=answer
    fi
    is_human=1 ;;
  pull_request)
    [ "$ACTION" = closed ] || say "pull_request.$ACTION is not read"
    if [ "$PR_MERGED" = true ]; then intent=merged; else intent=pr-closed; fi
    EVENT_ID="pr-$PR_NUMBER-$intent" ;;
  workflow_run)
    [ "$ACTION" = completed ] || say "workflow_run.$ACTION is not read"
    intent=evidence; EVENT_ID="wr-$WR_ID" ;;
  workflow_dispatch)
    case $D_REASON in
      chain|resume|redo|rework|retry|watchdog|evidence) intent=claim ;;
      finalize) intent=finalize ;;
      manual|"") intent=manual; is_human=1 ;;
      *) say "unknown dispatch reason '$D_REASON'" ;;
    esac ;;
  schedule) intent=watchdog ;;
  *) say "event $EVENT is not handled" ;;
esac
out event_id "$EVENT_ID"
[ "$intent" = command ] && [ "$SENDER_TYPE" != User ] && say "commands from a $SENDER_TYPE are ignored"
[ "$intent" = start ] && [ "$SENDER_TYPE" != User ] && say "labels from a $SENDER_TYPE are ignored"
if [ "$intent" = manual ]; then SENDER=$ACTOR; SENDER_TYPE=User; ISSUE=$D_ISSUE; fi
[ "$intent" = claim ] || [ "$intent" = finalize ] && ISSUE=$D_ISSUE
export ISSUE

# ── 2. G2 kill switch (fail closed) ─────────────────────────────────────────

halted() { # <reason>
  if [ "$intent" = watchdog ]; then say "halted: $1"; fi
  if case_is_human && [ -n "$ISSUE" ] && [ "$intent" != label-other ]; then
    reply "$ISSUE" "$EVENT_ID" "swarm is halted: $1" "$SENDER" >/dev/null || true
  fi
  say "halted: $1"
}
ctrl=$(gh api "repos/$REPO/issues?labels=swarm:control&state=all&per_page=1" 2>/dev/null) || halted "the swarm:control issue is unreadable"
printf '%s' "$ctrl" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || halted "no issue carries swarm:control"
[ "$(printf '%s' "$ctrl" | jq -r '.[0].state')" = open ] || halted "the swarm:control issue is closed"
if printf '%s' "$ctrl" | jq -e '[.[0].labels[].name] | any(. == "swarm:halt" or . == "swarm:halt-pipeline")' >/dev/null; then
  halted "the control issue carries swarm:halt"
fi

# ── 3. config (G27) ─────────────────────────────────────────────────────────

config_broken() { # <reason>
  case $intent in
    evidence|pr-closed|label-other|answer|hands-off-label|watchdog) say "config: $1" ;;
  esac
  say "config: $1" bad-handoff
}
if [ -z "${SWARM_STATE_KEY:-}" ]; then config_broken "SWARM_STATE_KEY is empty — the state cannot be signed or verified; set the repository secret"; fi
cfg_err=$(tmpf .cfgerr) || die "resolve: no temp dir"
CONFIG_JSON=$("$SWARM_LIB/config.sh" load --out "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swarm-config.json" 2> "$cfg_err") \
  || config_broken "$(tr '\n' ' ' < "$cfg_err" | head -c 400)"
export CONFIG_JSON
rm -f "$cfg_err"
STATE_BRANCH=$(C .state_branch); export STATE_BRANCH
stub=$(stub_file 2>/dev/null) || stub=""
if [ -n "$stub" ] && [ -f ".github/workflows/$stub" ]; then
  listed=$(yaml2json < ".github/workflows/$stub" 2>/dev/null | jq -c '((.on // .["true"] // {}) | .workflow_run.workflows // [])' 2>/dev/null) || listed="[]"
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    if ! printf '%s' "$listed" | jq -e --arg n "$wf" 'index($n) != null' >/dev/null 2>&1; then
      printf '::warning::evidence workflow "%s" is not in %s workflow_run.workflows — its completion never reaches the dispatcher\n' "$wf" "$stub"
      WARN+=" ⚠ evidence workflow \`$wf\` is not in the stub's \`workflow_run.workflows\` list"
    fi
  done < <(jq -r '.evidence // {} | .[]' "$CONFIG_JSON")
fi

# ── 3b. the watchdog ───────────────────────────────────────────────────────

if [ "$intent" = watchdog ]; then
  "$SWARM_LIB/watchdog.sh" || log "resolve: watchdog exited $?"
  say "watchdog tick done"
fi

# ── 4. derive the issue ────────────────────────────────────────────────────

issue_from_branch() { # <ref> → N when <prefix>N-…
  local prefix
  prefix=$(C .branch_prefix); [ -n "$prefix" ] || prefix="claude/issue-"
  [[ $1 == "$prefix"* ]] || return 1
  [[ ${1#"$prefix"} =~ ^([0-9]+)(-|$) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}
case $intent in
  command|answer)
    [ -n "$ISSUE" ] || say "no issue number on the event"
    if [ "$EVENT" = pull_request_review ]; then
      n=$(issue_from_branch "$PR_HEAD_REF") || n=""
      [ -n "$n" ] || n=$(issue_from_branch "$(gh pr view -R "$REPO" "$ISSUE" --json headRefName --jq .headRefName 2>/dev/null)") || n=""
      [ -n "$n" ] || { reply "$ISSUE" "$EVENT_ID" "this pull request is not a swarm branch (\`$(C .branch_prefix)<N>-…\`); commands go on the issue" "$SENDER" >/dev/null; say "review on a non-swarm PR #$ISSUE"; }
      PR_OF_EVENT=$ISSUE; ISSUE=$n
    fi ;;
  merged|pr-closed)
    n=$(issue_from_branch "$PR_HEAD_REF") || say "PR #$PR_NUMBER head '$PR_HEAD_REF' is not a swarm branch"
    ISSUE=$n ;;
  evidence)
    n=""
    if [[ $WR_TITLE =~ swarm#([0-9]+) ]]; then n=${BASH_REMATCH[1]}; else n=$(issue_from_branch "$WR_BRANCH") || n=""; fi
    [ -n "$n" ] || say "workflow_run $WR_ID ($WR_NAME on $WR_BRANCH) maps to no swarm issue"
    ISSUE=$n ;;
  claim|finalize|manual)
    [ -n "$ISSUE" ] || say "workflow_dispatch without an issue number" ;;
esac
export ISSUE
ISSUE_JSON=$(gh api "repos/$REPO/issues/$ISSUE" 2>/dev/null) || die "resolve: cannot read issue #$ISSUE — refusing to guess"
ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title // ""')
ISSUE_LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '.labels[]?.name // empty')
ISSUE_AUTHOR=${ISSUE_AUTHOR:-$(printf '%s' "$ISSUE_JSON" | jq -r '.user.login // ""')}
ISSUE_AUTHOR_TYPE=${ISSUE_AUTHOR_TYPE:-$(printf '%s' "$ISSUE_JSON" | jq -r '.user.type // ""')}
if [ "$intent" = command ] && [ "$EVENT" = issue_comment ] && printf '%s' "$ISSUE_JSON" | jq -e '.pull_request != null' >/dev/null 2>&1; then
  # a command on the PR's conversation maps to the issue through the head branch
  n=$(issue_from_branch "$(gh pr view -R "$REPO" "$ISSUE" --json headRefName --jq .headRefName 2>/dev/null)") || n=""
  [ -n "$n" ] || { reply "$ISSUE" "$EVENT_ID" "this pull request is not a swarm branch (\`$(C .branch_prefix)<N>-…\`); commands go on the issue" "$SENDER" >/dev/null; say "command on a non-swarm PR #$ISSUE"; }
  PR_OF_EVENT=$ISSUE; ISSUE=$n; export ISSUE
  ISSUE_JSON=$(gh api "repos/$REPO/issues/$ISSUE" 2>/dev/null) || die "resolve: cannot read issue #$ISSUE — refusing to guess"
  ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title // ""')
  ISSUE_LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '.labels[]?.name // empty')
  log "resolve: command on PR #$PR_OF_EVENT maps to issue #$ISSUE"
fi
out issue "$ISSUE"

# ── 5. state (G37) ─────────────────────────────────────────────────────────

rc=0
"$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2> "$STATE.err" 3>/dev/null || rc=$?
case $rc in
  0) HAVE_STATE=1 ;;
  3)
    if ! "$SWARM_LIB/state.sh" branch-exists "$REPO" 2>/dev/null; then
      config_broken "the state branch \`$STATE_BRANCH\` does not exist — run \`lib/sh/state.sh init-branch $REPO\`"
    fi ;;
  6)
    detail=$(grep -o 'commit [0-9a-f]*' "$STATE.err" | head -1)
    say "state #$ISSUE has a missing or mismatching signature (${detail:-commit unknown}) — someone wrote \`issues/$ISSUE.json\` without the key; revert that commit on \`$STATE_BRANCH\`, then /swarm resume" perimeter ;;
  *) cat "$STATE.err" >&2; die "resolve: cannot read state #$ISSUE (state.sh exit $rc)" ;;
esac
rm -f "$STATE.err"
export STATE_JSON=$STATE
[ $HAVE_STATE -eq 1 ] && pin_checkout

# hand-added swarm:hands-off follows the label (G4; a racing projection cannot un-veto)
if [ $HAVE_STATE -eq 1 ]; then
  if printf '%s\n' "$ISSUE_LABELS" | grep -qxF swarm:hands-off; then
    [ "$(S .flags.hands_off)" = true ] || write hands-off --arg value true --arg by "${SENDER:-label}" >/dev/null 2>&1 || true
  elif [ "$(S .flags.hands_off)" = true ]; then
    write hands-off --arg value false >/dev/null 2>&1 || true
  fi
fi

# ── 6. G4 veto ─────────────────────────────────────────────────────────────

# a lane sub-issue carries swarm:hands-off too; its answer names the parent, not the veto
if printf '%s\n' "$ISSUE_LABELS" | grep -qxF swarm:lane; then
  parent=$(printf '%s' "$ISSUE_TITLE" | sed -n -E 's/^\[#([0-9]+)\/.*$/\1/p')
  refuse_event "#$ISSUE is a lane sub-issue of #${parent:-?} — commands go on the parent issue"
fi
vetoed=0
printf '%s\n' "$ISSUE_LABELS" | grep -qxF swarm:hands-off && vetoed=1
[ $HAVE_STATE -eq 1 ] && [ "$(S .flags.hands_off)" = true ] && vetoed=1
if [ $vetoed -eq 1 ] && [ "$intent" != hands-off-label ] && ! { [ "$intent" = command ] && [ "$VERB" = status ]; }; then
  refuse_event "#$ISSUE is hands-off — the swarm ignores it until the label is removed by hand (\`/swarm status\` still answers)"
fi
if [ $HAVE_STATE -eq 1 ] && [ "$(status)" = dropped ]; then
  case $intent in
    command) case $VERB in start|status) ;; *) refuse_human "#$ISSUE was dropped — \`/swarm start\` resumes it" ;; esac ;;
    answer|label-other|hands-off-label) say "#$ISSUE is dropped" ;;
    claim) say "#$ISSUE is dropped; nothing runs" ;;
  esac
fi

# ── 7. by intent ───────────────────────────────────────────────────────────

case $intent in
  claim) claim "$D_REASON" ;;

  finalize)
    [ $HAVE_STATE -eq 1 ] || say "no state for #$ISSUE"
    [ "$(S .current.key)" = "$D_KEY" ] || say "finalize key $D_KEY is not current.key ($(S .current.key))"
    case $(status) in running|routing) ;; *) say "status is $(status); a finalize needs running/routing (after /swarm resume at blocked:stalled)" ;; esac
    run_job_completed "$(S .current.run_id)" || say "the run job of run $(S .current.run_id) has not completed; nothing to finalise"
    emit_role_outputs "$(S .stage)" "$(S .current.role)" "$D_KEY"
    out working_comment_id "$(S .current.comment_id)"
    out go false; out finalize true; out block ""; out reason "finalize $D_KEY from run $(S .current.run_id)"
    log "resolve: finalize $D_KEY from the handoff of run $(S .current.run_id)"
    exit 0 ;;

  manual)
    is_approver "$ACTOR" default || { reply "$ISSUE" "$EVENT_ID" "only $(approvers_for default | tr '\n' ' ' | sed 's/ $//') may dispatch the swarm from the Actions tab (actor: $ACTOR)" "$ACTOR" >/dev/null; say "manual dispatch by non-approver $ACTOR"; }
    if [ -z "$D_KEY" ]; then
      [ $HAVE_STATE -eq 1 ] || refuse_human "no v2 state for #$ISSUE; add \`swarm:ready\` or comment \`/swarm start\`"
      CMD='{"verb":"resume","args":""}'; VERB=resume
      do_resume
    fi
    [ $HAVE_STATE -eq 1 ] || refuse_human "no v2 state for #$ISSUE; add \`swarm:ready\` or comment \`/swarm start\`"
    if [ "$(status)" = queued ] && [ "$(S .next.key)" = "$D_KEY" ]; then claim manual; fi
    refuse_human "key \`$D_KEY\` does not match — $(status_line); the queued key is \`$(S '.next.key' | sed 's/^$/none/')\` (\`/swarm resume\` fires it)" ;;

  start)
    is_approver "$SENDER" default || { list=$(approvers_for default 2>/dev/null | tr '\n' ' ' | sed 's/ $//'); refuse_human "only ${list:-the configured approvers} may start the swarm (the \`swarm:ready\` label stays for an approver to see)"; }
    CMD='{"verb":"start","args":"","force":false}'; VERB=start
    do_start ;;

  hands-off-label)
    if [ $HAVE_STATE -eq 1 ]; then projection; fi
    ack "hands-off recorded for #$ISSUE — the swarm ignores it until the label is removed by hand"
    ok_done "hands-off label recorded" ;;

  label-other)
    if [ $HAVE_STATE -eq 1 ]; then
      projection
      say "label $LABEL_ADDED re-projected from state"
    fi
    reply "$ISSUE" "$EVENT_ID" "labels are written by the dispatcher (\`$LABEL_ADDED\` has no effect); add \`swarm:ready\` or comment \`/swarm start\` to start the swarm on #$ISSUE" "$SENDER" >/dev/null || true
    say "hand-added $LABEL_ADDED on an issue without v2 state (G33)" ;;

  answer)
    [ $HAVE_STATE -eq 1 ] || say "plain comment on #$ISSUE without state"
    { [ "$(status)" = gate ] && [ "$(S .gate.name)" = question ]; } || say "plain comment at $(status) — not an answer"
    allowed=0
    if [ "$SENDER" = "$ISSUE_AUTHOR" ] && [ "$ISSUE_AUTHOR_TYPE" = User ] && [ "$(C .reporter_may_answer)" != false ]; then allowed=1; fi
    is_approver "$SENDER" default && allowed=1
    [ $allowed -eq 1 ] || say "comment by $SENDER is neither the reporter's nor an approver's — not an answer"
    note=$(head -c 500 "$BODY_FILE" | tr '\n' ' ')
    write resume --arg mode question --arg by "$SENDER" --arg note "$note" >/dev/null || say "the question gate moved on — $(status_line)"
    projection
    ack "answer received from $SENDER — the analyst resumes as \`$(S .next.key)\`; anything you add before it starts is included"
    fire_next resume
    ok_done "answered; fired $(S '.next.key // .current.key')" ;;

  command)
    case $VERB in
      unknown) refuse_human "unknown command \`/swarm $(printf '%s' "$CMD" | jq -r '.input')\` — verbs: $("$SWARM_LIB/commands.sh" verbs | tr '\n' ' ' | sed 's/ $//')" ;;
    esac
    err=$(printf '%s' "$CMD" | jq -r '.error // empty')
    [ -z "$err" ] || refuse_human "$err"
    if [ $HAVE_STATE -eq 0 ] && [ "$VERB" != start ] && [ "$VERB" != hands-off ]; then
      if [ "$VERB" = status ]; then refuse_human "no v2 state for #$ISSUE — \`/swarm start\` or the \`swarm:ready\` label starts it"; fi
      refuse_human "no v2 state for #$ISSUE; \`/swarm start\` or the \`swarm:ready\` label starts the swarm"
    fi
    case $VERB in
      start) is_approver "$SENDER" default || refuse_human "only $(approvers_for default 2>/dev/null | tr '\n' ' ' | sed 's/ $//') may start the swarm"; do_start ;;
      approve) do_approve ;;
      reject) do_reject ;;
      resume) do_resume ;;
      redo) do_redo ;;
      skip) do_skip ;;
      park) do_park ;;
      drop) do_drop ;;
      hands-off) do_handsoff ;;
      path) do_path ;;
      status) do_status ;;
      *) refuse_human "unknown command \`/swarm $VERB\`" ;;
    esac ;;

  evidence)
    [ $HAVE_STATE -eq 1 ] || say "workflow_run $WR_ID maps to #$ISSUE, which has no v2 state"
    [ -n "$WR_SHA" ] && [ -n "$WR_NAME" ] || say "workflow_run $WR_ID carries no head sha or name"
    write evidence-seen --arg head "$WR_SHA" --arg workflow "$WR_NAME" --arg event "${WR_EVENT:-unknown}" --arg run_id "${WR_ID:-0}" \
      --arg conclusion "${WR_CONCLUSION:-unknown}" --arg url "$(run_url_of "${WR_ID:-0}")" >/dev/null || log "resolve: evidence-seen not recorded (state.sh exit $?)"
    log "resolve: recorded $WR_NAME ($WR_EVENT) on ${WR_SHA:0:7}: $WR_CONCLUSION"
    case $(status) in done|dropped) say "recorded; #$ISSUE is $(status)" ;; esac
    [ "$WR_CONCLUSION" != cancelled ] || say "recorded; run $WR_ID was cancelled (superseded by a newer push) — G19"
    [ "$(status)" = evidence ] || say "recorded at status $(status); nothing waits on it here"
    slot=$(S .evidence.pending.workflow); name=$(C ".evidence[\"$slot\"]"); [ -n "$name" ] || name=$slot
    [ "$WR_NAME" = "$name" ] || say "recorded; the pending wait is for \`$name\`, not \`$WR_NAME\`"
    [ "$WR_SHA" = "$(S .evidence.pending.head)" ] || say "recorded; the pending wait is on $(S .evidence.pending.head | cut -c1-7), not ${WR_SHA:0:7}"
    if [ "$slot" = ci ]; then
      expect_ev=push; [ -n "$(S .pr)" ] && expect_ev=pull_request
      [ "$WR_EVENT" = "$expect_ev" ] || say "recorded; the CI wait reads the $expect_ev run, this was $WR_EVENT"
    else
      [[ $WR_TITLE == *" $(S .evidence.pending.key)" ]] || say "recorded; run $WR_ID's title does not end with the pending key $(S .evidence.pending.key) (another wait's run)"
    fi
    consume_pending "$WR_CONCLUSION" "$WR_ID"
    ok_done "evidence consumed; fired $(S '.next.key // .current.key')" ;;

  merged)
    [ $HAVE_STATE -eq 1 ] || say "PR #$PR_NUMBER merged on #$ISSUE, which has no v2 state"
    if [ -n "$(S .pr)" ] && [ "$(S .pr)" != "$PR_NUMBER" ]; then
      reply "$ISSUE" "$EVENT_ID" "PR #$PR_NUMBER was merged from a swarm branch, but the swarm's pull request for #$ISSUE is #$(S .pr) — nothing recorded (G34)" >/dev/null || true
      say "PR mismatch: merged #$PR_NUMBER, state.pr is $(S .pr)"
    fi
    if ! gh pr view -R "$REPO" "$PR_NUMBER" --json body --jq .body 2>/dev/null | grep -qF "Swarm-Issue: #$ISSUE"; then
      printf '::warning::PR #%s carries no "Swarm-Issue: #%s" trailer\n' "$PR_NUMBER" "$ISSUE"
    fi
    if [ -n "$(S .merged_at)" ] || [ "$(S .stages.retro.status)" != pending ]; then
      reply "$ISSUE" "$EVENT_ID" "already merged at $(S .merged_at | sed 's/^$/?/'); retro $(S .stages.retro.status)" >/dev/null || true
      say "already merged at $(S .merged_at); retro $(S .stages.retro.status)"
    fi
    if [ "${PR_MERGED_BY_TYPE:-}" != User ] || ! is_approver "${PR_MERGED_BY:-}" release; then
      # G35: a merge by anyone but an approver is a perimeter event; no retro, no branch delete, no swarm:done
      detail="PR #$PR_NUMBER merged by ${PR_MERGED_BY:-?} (${PR_MERGED_BY_TYPE:-?}), not an approver for release; merge commit ${PR_MERGE_SHA:-?}"
      write block --arg reason perimeter --arg detail "$detail" >/dev/null || log "resolve: block perimeter not recorded (state.sh exit $?)"
      body=$(tmpf .md) || die "resolve: no temp dir"
      "$SWARM_LIB/render.sh" perimeter-merge "$body" --arg pr "$PR_NUMBER" --sarg merged_by "${PR_MERGED_BY:-?}" --arg merged_by_type "${PR_MERGED_BY_TYPE:-?}" \
        --arg approvers "$(approvers_for release | tr '\n' ' ' | sed 's/ $//')" --arg merge_sha "${PR_MERGE_SHA:-?}" --arg default_branch "$(default_branch)" \
        --arg marker "$(marker refused "event=$EVENT_ID")" || die "resolve: cannot render the perimeter comment"
      if existing=$(find_comment "$ISSUE" "$(marker_pred refused "event=$EVENT_ID")"); then
        cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" || true
      else
        cid=$(post_comment "$ISSUE" "$body") || log "resolve: perimeter comment not posted"
      fi
      rm -f "$body"
      [ -n "${cid:-}" ] && write comment-id --arg target blocked --arg comment_id "$cid" >/dev/null 2>&1
      projection
      say "blocked:perimeter — $detail"
    fi
    write pr-merged --arg pr "$PR_NUMBER" --arg by "$PR_MERGED_BY" --arg merge_sha "${PR_MERGE_SHA:-}" --arg merged_at "$(now)" >/dev/null \
      || say "merge of PR #$PR_NUMBER not recorded — the state moved on ($(status_line))"
    while IFS= read -r sub; do
      [ -n "$sub" ] && [ "$sub" != null ] || continue
      gh issue close -R "$REPO" "$sub" --comment "Merged in PR #$PR_NUMBER (#$ISSUE)." >/dev/null 2>&1 || log "resolve: sub-issue #$sub not closed"
    done < <(jq -r '.subissues // {} | to_entries[] | select(.key != "flat") | .value' "$STATE")
    projection
    fire_next chain
    ok_done "merged PR #$PR_NUMBER by $PR_MERGED_BY; retro fired as $(S '.next.key // .current.key')" ;;

  pr-closed)
    [ $HAVE_STATE -eq 1 ] || say "PR #$PR_NUMBER closed on #$ISSUE, which has no v2 state"
    [ -z "$(S .merged_at)" ] || say "PR #$PR_NUMBER closed after the merge; nothing to park"
    case $(status) in done|dropped|parked) say "PR #$PR_NUMBER closed; #$ISSUE is $(status)" ;; esac
    write park --arg by "${SENDER:-unknown}" --arg note "PR #$PR_NUMBER closed without merging" >/dev/null || say "cannot park #$ISSUE — $(status_line)"
    projection
    reply "$ISSUE" "$EVENT_ID" "PR #$PR_NUMBER was closed without merging (by ${SENDER:-?}) — #$ISSUE is parked; \`/swarm resume\` continues, \`/swarm drop\` abandons (the branch is kept)" >/dev/null || true
    ok_done "PR #$PR_NUMBER closed unmerged; parked" ;;
esac
say "intent $intent fell through"
