#!/usr/bin/env bash
# watchdog.sh — the scheduled sweep (spec §5.4, G25, G26, G31, G33 residue, G37),
# run inside `resolve` on `schedule`; no LLM, ≈ 1 billed minute, twice a day.
#
#   1. Lists every issue with a `swarm:` label, state=all (a merged issue at
#      swarm:retro is closed), touched in the last 45 days.
#   2. For each with a verified state file: G25 — re-fire a queued dispatch whose run
#      was cancelled or vanished (after queued_refire_minutes), fire a queued dispatch
#      whose not_before has passed, comment on a queued dispatch whose fire was claimed
#      but never verified (never re-fired: that is the forgeable case), unclaim + re-fire
#      a running dispatch whose run was cancelled before its run job started, block
#      `stalled` a running dispatch with no live run past running_stall_minutes, record
#      and consume a pending evidence run that completed unnoticed, block `evidence`
#      after evidence_timeout_minutes; G26 — a gate reminder after gate_reminder_days,
#      then every 7 days, editing the same comment. Every re-fire goes through fire.sh.
#      An unverified state file (bad signature) is never acted on: its labels say
#      blocked:perimeter and the control note names it.
#   3. Open, hand-labelled issues without state get one reply (G33 residue).
#   4. Config and stub sanity (G27) go to the control issue's `kind=watchdog` comment.
#   5. Any issue at blocked:auth → the same comment says "renew CLAUDE_CODE_OAUTH_TOKEN".
#   6. This month's minutes/USD (billing endpoint when readable, else state sums) and
#      artifact storage, with today's refusals and repeated fire failures, in the same
#      comment; ⚠ at 80 % of a monthly limit.
#
# Environment: REPO, OWNER, SWARM_STATE_KEY, CONFIG_JSON (loaded here when unset),
# WORKFLOW_REF (the stub), RUN_ID, GH_TOKEN (contents/issues/actions write), SWARM_TOKEN
# (billing endpoint only), SWARM_NOW. Exit 0 always; the summary goes to stdout.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

require_env REPO
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
export RUN_ID
OWNER=${OWNER:-${REPO%%/*}}
export OWNER
PIPELINE="$SWARM_ROOT/pipeline.json"
NOW=$(now)
NOW_S=$(jq -rn --arg t "$NOW" '$t | fromdateiso8601')
TODAY=${NOW:0:10}

notes_config=()
notes_fire=()
notes_refusals=()
auth_issues=()
acted=()

cfg() { # <jq path> <default>
  local v=""
  if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then v=$(jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null); fi
  printf '%s\n' "${v:-$2}"
}

# ── 4. config and stub (G27) ─────────────────────────────────────────────────

if [ -z "${SWARM_STATE_KEY:-}" ]; then notes_config+=("SWARM_STATE_KEY is empty — nothing can be signed or verified"); fi
if [ -z "${CONFIG_JSON:-}" ] || [ ! -f "$CONFIG_JSON" ]; then
  cfg_err=$(tmpf .cfgerr) || die "watchdog: no temp dir"
  if CONFIG_JSON=$("$SWARM_LIB/config.sh" load --out "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swarm-config.json" 2> "$cfg_err"); then
    export CONFIG_JSON
  else
    notes_config+=("$(tr '\n' ' ' < "$cfg_err" | head -c 300)")
    CONFIG_JSON=""
  fi
  rm -f "$cfg_err"
fi
STATE_BRANCH=$(cfg .state_branch swarm/state)
export STATE_BRANCH
if [ -n "${SWARM_STATE_KEY:-}" ] && ! "$SWARM_LIB/state.sh" branch-exists "$REPO" 2>/dev/null; then
  notes_config+=("state branch \`$STATE_BRANCH\` missing — run \`lib/sh/state.sh init-branch $REPO\`")
fi
stub=$(stub_file 2>/dev/null) || stub=""
if [ -n "$stub" ] && [ -f ".github/workflows/$stub" ] && [ -n "$CONFIG_JSON" ]; then
  listed=$(yaml2json < ".github/workflows/$stub" 2>/dev/null | jq -c '((.on // .["true"] // {}) | .workflow_run.workflows // [])' 2>/dev/null) || listed="[]"
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    printf '%s' "$listed" | jq -e --arg n "$wf" 'index($n) != null' >/dev/null 2>&1 \
      || notes_config+=("evidence workflow \`$wf\` is not in \`$stub\` workflow_run.workflows")
  done < <(jq -r '.evidence // {} | .[]' "$CONFIG_JSON")
fi

refire_min=$(cfg .watchdog.queued_refire_minutes 30)
stall_min=$(cfg .watchdog.running_stall_minutes 20)
evidence_min=$(cfg .watchdog.evidence_timeout_minutes 120)
reminder_days=$(cfg .watchdog.gate_reminder_days 3)
runaway=$(cfg .limits.runaway_per_hour 10)

age_minutes() { # <iso> → minutes since
  [ -n "${1:-}" ] && [ "$1" != null ] || { echo 0; return; }
  jq -rn --arg t "$1" --argjson n "$NOW_S" '(($n - ($t | fromdateiso8601)) / 60) | floor'
}

# ── per-issue helpers ───────────────────────────────────────────────────────

STATE=""
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }

write() { # <transition> args… on $ISSUE; refreshes $STATE
  local rc=0 o
  o=$(tmpf .w) || return 1
  "$SWARM_LIB/state.sh" write "$ISSUE" "$@" > "$o" 2>/dev/null || rc=$?
  [ $rc -eq 0 ] && mv -f "$o" "$STATE"
  rm -f "$o"
  return $rc
}

projection() {
  "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" >/dev/null 2>&1 || true
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || true
}

run_info() { # <run_id> → {status, conclusion, run_job_started}
  gh run view -R "$REPO" "$1" --json status,conclusion,jobs 2>/dev/null | jq -c '
    {status: (.status // null), conclusion: (.conclusion // null),
     run_job_started: ([.jobs[]? | select(.name | test("^run-(read|write)")) | select(.startedAt != null)] | length > 0),
     found: (has("status"))}' 2>/dev/null || echo '{"found": false}'
}

too_many_dispatches() {
  local n
  n=$(jq -r --argjson now "$NOW_S" '[(.dispatches // [])[] | select(((.at // "1970-01-01T00:00:00Z") | fromdateiso8601) >= ($now - 3600))] | length' "$STATE")
  [ "$n" -ge "$runaway" ]
}

fire_next() { # <reason>
  local stage role key rc=0
  stage=$(S .next.stage); role=$(S .next.role); key=$(S .next.key)
  [ -n "$key" ] || return 0
  if too_many_dispatches; then
    write block --arg reason runaway --arg detail "watchdog: $runaway or more dispatches in the last hour" >/dev/null 2>&1 || true
    projection
    acted+=("#$ISSUE blocked:runaway")
    return 0
  fi
  "$SWARM_LIB/fire.sh" "$ISSUE" "$stage" "$role" "$key" "$1" >/dev/null 2>&1 || rc=$?
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
  if [ $rc -ne 0 ]; then notes_fire+=("#$ISSUE: fire of $key failed (blocked:fire)"); acted+=("#$ISSUE fire failed $key"); return 1; fi
  acted+=("#$ISSUE fired $key")
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || true
  return 0
}

# post_or_edit <kind-topic> <file>: one comment per (issue, topic), edited afterwards; prints the id
post_or_edit() {
  local topic=$1 file=$2 existing cid
  if existing=$(find_comment "$ISSUE" "$(marker_pred watchdog "topic=$topic")"); then
    cid=$(printf '%s' "$existing" | jq -r .id)
    edit_comment "$cid" "$file" >/dev/null 2>&1 || true
    printf '%s\n' "$cid"
  else
    post_comment "$ISSUE" "$file" 2>/dev/null
  fi
}

# comment_at <topic> → the `at=` of the existing comment's marker (empty when none);
# `at` is the marker's last field, which common.sh's marker_get does not read
comment_at() {
  local existing
  existing=$(find_comment "$ISSUE" "$(marker_pred watchdog "topic=$1")") || return 1
  printf '%s' "$existing" | jq -r .body | grep -oE '<!-- swarm: v2 [^>]*-->' | head -1 | grep -oE ' at=[0-9TZ:.-]+' | head -1 | sed 's/^ at=//'
}

consume_pending() { # <conclusion> <run_id>
  local consumer key stage base lane req rc=0 repro
  consumer=$(S .evidence.pending.consumer); key=$(S .evidence.pending.key); stage=$(S .stage)
  base=${consumer%%:*}; lane=""; [ "$base" != "$consumer" ] && lane=${consumer#*:}
  req=$(jq -r --arg s "$stage" --arg r "$base" '.stages[] | select(.name == $s) | .roles[] | select(.name == $r) | .requires_ci // empty' "$PIPELINE" 2>/dev/null | head -1)
  if [ "$(S .evidence.pending.workflow)" = ci ] && [ "$req" = success ] && [ "$1" != success ]; then
    [ -n "$lane" ] || lane=$(S '.lanes[0]')
    repro=$(gh run view -R "$REPO" "$2" --log-failed 2>/dev/null | tail -n 120 | redact)
    [ -n "$repro" ] || repro="CI concluded $1 (run $2); no failed-job log was available"
    write rework --arg from ci-red --arg to "dev:$lane" --arg stage build --arg reason "$repro" --arg from_key "$key" >/dev/null || rc=$?
    if [ $rc -eq 5 ]; then
      write block --arg reason budget --arg detail "rework budget exhausted; CI red on $(S .evidence.pending.head | cut -c1-7)" >/dev/null 2>&1 || true
      projection; acted+=("#$ISSUE blocked:budget"); return 0
    fi
  else
    write dispatch-queued --arg stage "$stage" --arg role "$consumer" --arg from_key "$key" --arg reason evidence >/dev/null || { acted+=("#$ISSUE evidence consume refused (state moved on)"); return 0; }
  fi
  projection
  fire_next watchdog
}

block_with_comment() { # <reason> <detail> <template> [render args…]
  local reason=$1 detail=$2 tmpl=$3 body cid existing
  shift 3
  write block --arg reason "$reason" --arg detail "$detail" >/dev/null 2>&1 || { acted+=("#$ISSUE block $reason refused (state moved on)"); return 0; }
  body=$(tmpf .md) || die "watchdog: no temp dir"
  if "$SWARM_LIB/render.sh" "$tmpl" "$body" "$@" --arg marker "$(marker died "key=$(S '.current.key // .evidence.pending.key // .next.key' | sed 's/^$/none/')" "status=died")"; then
    if existing=$(find_comment "$ISSUE" "$(marker_pred died "key=$(S '.current.key // .evidence.pending.key // .next.key' | sed 's/^$/none/')")"); then
      cid=$(printf '%s' "$existing" | jq -r .id); edit_comment "$cid" "$body" >/dev/null 2>&1 || true
    else
      cid=$(post_comment "$ISSUE" "$body" 2>/dev/null) || cid=""
    fi
    [ -n "$cid" ] && write comment-id --arg target blocked --arg comment_id "$cid" >/dev/null 2>&1
  fi
  rm -f "$body"
  projection
  acted+=("#$ISSUE blocked:$reason")
}

# ── 1. the issues ───────────────────────────────────────────────────────────

since=$(jq -rn --argjson n "$NOW_S" '($n - 45 * 86400) | todateiso8601')
issues=$(gh_json --paginate "repos/$REPO/issues?state=all&per_page=100&since=$since" 2>/dev/null \
  | jq -c '[.[]? | select(.pull_request == null) | select(any(.labels[]?.name; startswith("swarm:")) and (any(.labels[]?.name; . == "swarm:control") | not))
           | {number, state, labels: [.labels[].name], title}]') || issues="[]"
count=$(printf '%s' "$issues" | jq 'length')
log "watchdog: $count swarm issue(s) since $since"

for row in $(printf '%s' "$issues" | jq -r '.[] | @base64'); do
  entry=$(printf '%s' "$row" | base64 -d)
  ISSUE=$(printf '%s' "$entry" | jq -r .number)
  export ISSUE
  labels=$(printf '%s' "$entry" | jq -r '.labels[]')
  STATE=$(tmpf .state) || die "watchdog: no temp dir"
  rc=0
  "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2> "$STATE.err" 3>/dev/null || rc=$?
  case $rc in
    0) ;;
    3)
      rm -f "$STATE" "$STATE.err"
      # G33 residue: an open, hand-labelled issue with no state gets one reply
      if [ "$(printf '%s' "$entry" | jq -r .state)" = open ] && printf '%s\n' "$labels" | grep -E '^swarm:' | grep -qvE '^swarm:(ready|hands-off|lane|halt|halt-pipeline)$'; then
        reply "$ISSUE" "watchdog-nostate-$ISSUE" "labels are written by the dispatcher; #$ISSUE has no v2 state — add \`swarm:ready\` or comment \`/swarm start\` to start it" >/dev/null 2>&1 \
          && acted+=("#$ISSUE hand-labelled without state: replied")
      fi
      continue ;;
    6)
      commit=$(grep -o 'commit [0-9a-f]*' "$STATE.err" | head -1)
      rm -f "$STATE" "$STATE.err"
      notes_config+=("#$ISSUE: state signature invalid (${commit:-commit unknown}) — never acted on; revert that commit on \`$STATE_BRANCH\`")
      if ! printf '%s\n' "$labels" | grep -qxF blocked:perimeter; then
        printf '{"labels": ["swarm:blocked", "blocked:perimeter"]}' | gh api -X POST "repos/$REPO/issues/$ISSUE/labels" --input - >/dev/null 2>&1 || true
      fi
      acted+=("#$ISSUE signature invalid: labelled blocked:perimeter, nothing fired")
      continue ;;
    *) rm -f "$STATE" "$STATE.err"; notes_config+=("#$ISSUE: state unreadable (state.sh exit $rc)"); continue ;;
  esac
  rm -f "$STATE.err"
  export STATE_JSON=$STATE

  # today's refusals, auth and fire failures feed the control note
  while IFS= read -r l; do [ -n "$l" ] && notes_refusals+=("#$ISSUE: $l"); done < <(jq -r --arg d "$TODAY" '.refusals // {} | to_entries[] | select(.value == $d) | .key' "$STATE")
  if [ "$(S .status)" = blocked ]; then
    case $(S .blocked.reason) in
      auth) auth_issues+=("#$ISSUE") ;;
      fire) notes_fire+=("#$ISSUE: blocked:fire since $(S .blocked.at) — $(S .blocked.detail | head -c 120)") ;;
    esac
  fi
  if [ "$(S .flags.hands_off)" = true ] || printf '%s\n' "$labels" | grep -qxF swarm:hands-off; then
    rm -f "$STATE"
    continue
  fi

  case $(S .status) in
    queued)
      key=$(S .next.key); fired_at=$(S .next.fired_at); rid=$(S .next.fired_run_id); nb=$(S .next.not_before)
      if [ -z "$fired_at" ]; then
        if [ -z "$nb" ] || jq -e --argjson n "$NOW_S" '(.next.not_before | fromdateiso8601) <= $n' "$STATE" >/dev/null; then
          log "watchdog: #$ISSUE queued $key never fired — firing"
          fire_next watchdog
        fi
      elif [ -z "$rid" ]; then
        if [ "$(age_minutes "$fired_at")" -ge "$refire_min" ]; then
          body=$(tmpf .md) || die "watchdog: no temp dir"
          {
            printf '🐕 **watchdog** · #%s has been queued as `%s` since %s with a fire that was never verified (no run id). The watchdog never re-fires a claim it cannot explain; `/swarm resume` re-fires it.\n' "$ISSUE" "$key" "$fired_at"
            marker watchdog "topic=queued" "key=$key"
          } > "$body"
          post_or_edit queued "$body" >/dev/null
          rm -f "$body"
          acted+=("#$ISSUE queued $key: fire never verified — asked for /swarm resume")
        fi
      else
        info=$(run_info "$rid")
        st=$(printf '%s' "$info" | jq -r '.status // ""'); concl=$(printf '%s' "$info" | jq -r '.conclusion // ""'); found=$(printf '%s' "$info" | jq -r '.found')
        case $st in
          in_progress|queued|waiting|pending|requested) ;;
          *)
            if [ "$(age_minutes "$fired_at")" -ge "$refire_min" ]; then
              log "watchdog: #$ISSUE queued $key: run $rid is ${st:-gone} (${concl:-no conclusion}, found=$found) — re-firing"
              fire_next watchdog
            fi ;;
        esac
      fi ;;
    running|routing)
      rid=$(S .current.run_id); key=$(S .current.key)
      if [ -n "$rid" ] && [ "$rid" != 0 ]; then
        info=$(run_info "$rid")
        st=$(printf '%s' "$info" | jq -r '.status // ""'); concl=$(printf '%s' "$info" | jq -r '.conclusion // ""')
        started=$(printf '%s' "$info" | jq -r '.run_job_started')
        case $st in
          in_progress|queued|waiting|pending|requested) ;;
          *)
            if [ "$(age_minutes "$(S '.current.claimed_at // .current.started_at')")" -ge "$stall_min" ]; then
              if [ "$concl" = cancelled ] && [ "$started" != true ]; then
                log "watchdog: #$ISSUE run $rid was cancelled before its run job started — unclaim and re-fire"
                if write dispatch-unclaim --arg key "$key" --arg run_id "$rid" >/dev/null; then
                  cid=$(S '.dispatches[] | select(.key == "'"$key"'" and .run_id == '"$rid"') | .comment_id')
                  if [ -n "$cid" ] && [ "$cid" != null ]; then
                    body=$(tmpf .md) || die "watchdog: no temp dir"
                    "$SWARM_LIB/render.sh" stage-requeued "$body" --arg emoji "$(jq -r --arg r "${key#*:*:}" '.emoji[($r | split(":")[0])] // "🧭"' "$PIPELINE")" \
                      --arg role "$(S .next.role)" --arg attempt "${key##*:}" --arg run_id "$rid" --arg at "$NOW" --arg key "$key" \
                      --arg marker "$(marker stage "stage=$(S .stage)" "role=$(S .next.role)" "attempt=${key##*:}" "key=$key" "run=$rid" "status=requeued")" \
                      && edit_comment "$cid" "$body" >/dev/null 2>&1
                    rm -f "$body"
                  fi
                  projection
                  fire_next watchdog
                fi
              else
                block_with_comment stalled "run $rid is ${st:-gone} (${concl:-no conclusion}) and no finaliser ran" died \
                  --arg role "$(S .current.role)" --arg cause "stalled: run $rid ${st:-gone}, ${concl:-no conclusion}" \
                  --arg advice "/swarm resume finalises a completed run job from its handoff, or re-runs the role" \
                  --arg attempt "$(S .current.attempt)" --arg run_url "https://github.com/$REPO/actions/runs/$rid" \
                  --arg details "Claimed at $(S .current.claimed_at); the watchdog found no live run after $stall_min minutes."
              fi
            fi ;;
        esac
      fi ;;
    evidence)
      rid=$(S .evidence.pending.run_id); head=$(S .evidence.pending.head); slot=$(S .evidence.pending.workflow)
      name=$(cfg ".evidence[\"$slot\"]" "$slot")
      waited_since=$(jq -r '[.log[]? | select(.event | IN("evidence-wait", "evidence-fire"))] | last | .at // empty' "$STATE")
      [ -n "$waited_since" ] || waited_since=$(S '.evidence.pending.fired_at')
      handled=0
      if [ -n "$rid" ] && [ "$rid" != 0 ]; then
        info=$(gh run view -R "$REPO" "$rid" --json status,conclusion,event,url 2>/dev/null) || info="{}"
        if [ "$(printf '%s' "$info" | jq -r '.status // ""')" = completed ]; then
          concl=$(printf '%s' "$info" | jq -r '.conclusion // "unknown"'); ev=$(printf '%s' "$info" | jq -r '.event // "workflow_dispatch"')
          write evidence-seen --arg head "$head" --arg workflow "$name" --arg event "$ev" --arg run_id "$rid" --arg conclusion "$concl" --arg url "$(printf '%s' "$info" | jq -r '.url // ""')" >/dev/null 2>&1 || true
          log "watchdog: #$ISSUE pending $name run $rid completed ($concl) unnoticed — consuming"
          if [ "$concl" = cancelled ]; then
            handled=0
          else
            consume_pending "$concl" "$rid"; handled=1
          fi
        fi
      else
        o=$(tmpf .ev) || die "watchdog: no temp dir"
        ( GITHUB_OUTPUT=$o "$SWARM_LIB/evidence.sh" wait "$slot" "$head" "$(S .evidence.pending.consumer)" ) >/dev/null 2>&1 || true
        if [ "$(sed -n 's/^evidence_status=//p' "$o" | tail -1)" = complete ]; then
          "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
          consume_pending "$(sed -n 's/^evidence_conclusion=//p' "$o" | tail -1)" "$(sed -n 's/^evidence_run_id=//p' "$o" | tail -1)"; handled=1
        fi
        rm -f "$o"
        "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null 3>/dev/null || true
      fi
      if [ $handled -eq 0 ] && [ "$(S .status)" = evidence ] && [ -n "$waited_since" ] && [ "$(age_minutes "$waited_since")" -ge "$evidence_min" ]; then
        block_with_comment evidence "no completed $name run for $(printf '%s' "$head" | cut -c1-7) after $evidence_min minutes" died \
          --arg role "evidence:$slot" --arg cause "evidence timeout: $name on $(printf '%s' "$head" | cut -c1-7) after $evidence_min min" \
          --arg advice "/swarm resume re-queries GitHub for the run" --arg attempt "${rid:-0}" \
          --arg run_url "$( [ -n "$rid" ] && [ "$rid" != 0 ] && printf 'https://github.com/%s/actions/runs/%s' "$REPO" "$rid" || printf 'no run recorded' )" \
          --arg details "Waiting since $waited_since for the \`$name\` workflow (key $(S .evidence.pending.key))."
      fi ;;
    gate)
      since_gate=$(S .gate.since); g=$(S .gate.name)
      if [ "$(age_minutes "$since_gate")" -ge $((reminder_days * 1440)) ]; then
        last=$(comment_at gate-reminder) || last=""
        if [ -z "$last" ] || [ "$(age_minutes "$last")" -ge $((7 * 1440)) ]; then
          approver=$(approvers_for "$g" 2>/dev/null | head -1); [ -n "$approver" ] || approver=$OWNER
          case $g in
            release) hint="merge PR #$(S .pr) to release, or \`/swarm reject <why>\`" ;;
            question) hint="reply in plain text, or \`/swarm resume\` to proceed on the stated assumptions" ;;
            budget) hint="\`/swarm approve\` raises the cap; \`/swarm park\` or \`/swarm drop\`" ;;
            *) hint="\`/swarm approve\` or \`/swarm reject <why>\`" ;;
          esac
          body=$(tmpf .md) || die "watchdog: no temp dir"
          {
            printf '🐕 **watchdog** · @%s, #%s has been waiting at the `%s` gate since %s (%s days). %s\n' "$approver" "$ISSUE" "$g" "$since_gate" "$(( $(age_minutes "$since_gate") / 1440 ))" "$hint"
            marker watchdog "topic=gate-reminder" "gate=$g"
          } > "$body"
          post_or_edit gate-reminder "$body" >/dev/null
          rm -f "$body"
          acted+=("#$ISSUE gate $g reminder")
        fi
      fi ;;
  esac
  rm -f "$STATE"
done

# ── 5/6. the control note ───────────────────────────────────────────────────

ctrl=$(gh api "repos/$REPO/issues?labels=swarm:control&state=all&per_page=1" --jq '.[0].number // empty' 2>/dev/null) || ctrl=""

limit_min=$(cfg .limits.runner_minutes_month 1500)
limit_usd=$(cfg .limits.usd_month 200)
totals=$("$SWARM_LIB/state.sh" month-totals "$REPO" 2>/dev/null) || totals='{}'
used=$("$SWARM_LIB/state.sh" billing-used "$OWNER" 2>/dev/null)
source_note="billing endpoint"
if [ -z "$used" ]; then used=$(printf '%s' "$totals" | jq -r '.minutes // 0'); source_note="state files"; fi
usd=$(printf '%s' "$totals" | jq -r '.cost_usd // 0')
usage="$used/$limit_min min ($source_note) · \$$usd/\$$limit_usd"
if jq -e -n --argjson u "${used:-0}" --argjson l "$limit_min" '$l > 0 and $u >= $l * 0.8' >/dev/null 2>&1 \
   || jq -e -n --argjson u "${usd:-0}" --argjson l "$limit_usd" '$l > 0 and $u >= $l * 0.8' >/dev/null 2>&1; then
  usage="⚠ $usage — at or above 80 % of a monthly limit"
fi
cache_b=$(gh api "repos/$REPO/actions/cache/usage" --jq '.active_caches_size_in_bytes // 0' 2>/dev/null) || cache_b=0
art_b=$(gh_json --paginate "repos/$REPO/actions/artifacts?per_page=100" 2>/dev/null | jq -r '[.artifacts[]? | select(.expired != true) | .size_in_bytes // 0] | add // 0') || art_b=0
storage=$(jq -rn --argjson c "${cache_b:-0}" --argjson a "${art_b:-0}" '"caches \(($c / 1048576 * 10 | round) / 10) MB · artifacts \(($a / 1048576 * 10 | round) / 10) MB"')

config_line="ok"; [ ${#notes_config[@]} -gt 0 ] && config_line=$(printf '%s; ' "${notes_config[@]}" | sed 's/; $//')
auth_line="ok"
[ ${#auth_issues[@]} -gt 0 ] && auth_line="renew \`CLAUDE_CODE_OAUTH_TOKEN\` (\`claude setup-token\`, then \`gh secret set CLAUDE_CODE_OAUTH_TOKEN\`); ${#auth_issues[@]} issue(s) waiting: ${auth_issues[*]} — \`/swarm resume\` each after the renewal"
ref_line="none"; [ ${#notes_refusals[@]} -gt 0 ] && ref_line=$(printf '%s; ' "${notes_refusals[@]}" | sed 's/; $//')
fire_line="none"; [ ${#notes_fire[@]} -gt 0 ] && fire_line=$(printf '%s; ' "${notes_fire[@]}" | sed 's/; $//')

if [ -n "$ctrl" ]; then
  ISSUE=$ctrl
  export ISSUE
  body=$(tmpf .md) || die "watchdog: no temp dir"
  if "$SWARM_LIB/render.sh" watchdog "$body" --arg at "$NOW" --sarg config "$config_line" --arg auth "$auth_line" --arg usage "$usage" \
       --arg storage "$storage" --sarg refusals "$ref_line" --sarg fire_failures "$fire_line" \
       --arg marker "$(marker watchdog "issue=$ctrl" "topic=control")"; then
    post_or_edit control "$body" >/dev/null || log "watchdog: control note not posted"
  fi
  rm -f "$body"
else
  log "watchdog: no swarm:control issue — the control note has nowhere to go"
fi

printf 'watchdog: %s issue(s) scanned; %s action(s)\n' "$count" "${#acted[@]}"
for a in "${acted[@]}"; do printf '  %s\n' "$a"; done
printf 'usage: %s · storage: %s · auth: %s\n' "$usage" "$storage" "$auth_line"
exit 0
