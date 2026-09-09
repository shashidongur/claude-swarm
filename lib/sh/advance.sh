#!/usr/bin/env bash
# advance.sh — the step finaliser (spec §16.1.3, §4.4, §5.3, §7.3, §9.1, §11.2, §11.5).
# Runs in the dispatcher's `advance` job after the run job(s) of one dispatch, from a
# fresh swarm checkout at swarm_sha and a fresh project checkout, with the handoff
# artifact downloaded into $RUN_DIR (.swarm-run). Everything it records is re-derived
# here — the run job's outputs are claims.
#
#   advance.sh                     (inputs from the environment; see below)
#
# Steps, in this order:
#   1  load: the verified state (G37 → a perimeter comment + red job: an unsigned file
#      cannot be CAS-written), config, pipeline.json, the handoff (result.json, the
#      in-job validation.json as advisory), the critic's file + execution file, the
#      execution stats (exec-stats.sh)
#   2  the unclaimed / cancelled-pending rule (§4.4): no record (KEY, RUN_ID) → exit 0
#      with a log line; a `running` record whose run job was cancelled/skipped before it
#      ran (no handoff) → dispatch-unclaim, "re-queued" comment, one fire (G6 first)
#   3  idempotency: a finished/died/invalid record → "already finalised", exit 0;
#      RUN_ATTEMPT > 1 with a failed begin → one reply, exit 0; a record another
#      dispatch superseded → the comment says so, exit 0
#   4  authoritative validation (validate-result.sh --authoritative) and, when the run
#      job died without a valid result, the G21 classification (max-turns / timeout /
#      cancelled / auth / ratelimit / error) from the execution file and the failed log
#   5  critic acceptance: the file counts only when the critic's own execution file
#      shows a Write of .swarm-run/critic.json and its target_key is this key
#   6  G32 (model map), G29 perimeter: (a) protected paths in the attempt's diff,
#      (b) perimeter.sh manifests, (c) the base is still an ancestor, (d) perimeter.sh
#      activity since the claim, (e) a read-class run left the tree/branch alone (V18);
#      (f) — .github/** before an evidence fire — is route.sh's
#   7  dispatch-finished / dispatch-died / dispatch-invalid with the stats (cost, turns,
#      duration, job minutes, overhead minutes, models, head, validation errors,
#      redacted last text) — BEFORE any routing, whatever the status (running → routing;
#      parked / dropped / blocked:stalled keep the record and route nothing)
#   8  finished: commit-artifacts.sh (push while state.pr == null, else stage pending),
#      clear the pending entries the pushed head carries, subissues (route.sh, from the
#      planner's result), pr-opened when a write role opened the PR
#   9  the working comment edited into its final form, labels.sh project (when
#      installed), the state comment re-rendered
#  10  route.sh — routing fires the successor; parked/dropped name it and fire nothing;
#      queued/evidence/gate/done (a merge landed mid-stage) record only, and the
#      comment says what the issue is doing; a died run: one automatic retry (max-turns/error,
#      attempt 1), a ratelimit back-off (queued with not_before), blocked:auth, or
#      blocked:agent-output; an invalid result: blocked:agent-output with the errors
#  11  the blast radius before release lives in route.sh
# Everything is logged to $RUN_DIR/advance.log (uploaded when the job fails).
#
# Environment: ISSUE (or D_ISSUE), KEY (or D_KEY), RUN_ID, RUN_ATTEMPT, REPO,
# SWARM_STATE_KEY, GH_TOKEN; the run-job facts RUN_READ_RESULT, RUN_WRITE_RESULT,
# CRITIC_RESULT (needs.*.result), ROLE_OUTCOME, RETRY_OUTCOME, BEGIN_OUTCOME, VALID
# (advisory), FINALIZE (true when re-finalising from a stored handoff — the record and
# the job minutes are then those of current.run_id, not of this run); optional
# overrides MODEL (requested), WORKING_COMMENT_ID, EXEC, RETRY_EXEC, CRITIC_EXEC,
# CONFIG_JSON (default $RUN_DIR/config.json, else config.sh load), RUN_DIR;
# WORKFLOW_REF or STUB_FILE (fires); SWARM_TOKEN / SWARM_REPO / SWARM_REF (retro).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${ISSUE:-${D_ISSUE:-}}
KEY=${KEY:-${D_KEY:-}}
RUN_ID=${RUN_ID:-${GITHUB_RUN_ID:-0}}
RUN_ATTEMPT=${RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}
[ -n "$ISSUE" ] && [ -n "$KEY" ] || die "advance: ISSUE and KEY are required"
require_env REPO SWARM_STATE_KEY
export ISSUE RUN_ID
RUN_DIR=${RUN_DIR:-.swarm-run}
ADV="$RUN_DIR/advance"
mkdir -p "$ADV"
LOGF="$RUN_DIR/advance.log"
log() { printf '%s\n' "$*" >&2; printf '%s advance: %s\n' "$(now)" "$*" >> "$LOGF" 2>/dev/null || true; }
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
export RUN_URL
PIPELINE="$SWARM_ROOT/pipeline.json"
[ -f "$PIPELINE" ] || die "advance: $PIPELINE is missing"
RESULT="$RUN_DIR/result.json"
log "advance #$ISSUE $KEY run $RUN_ID attempt $RUN_ATTEMPT (read=${RUN_READ_RESULT:-} write=${RUN_WRITE_RESULT:-} critic=${CRITIC_RESULT:-} role=${ROLE_OUTCOME:-} begin=${BEGIN_OUTCOME:-} finalize=${FINALIZE:-false})"

# ── 1. load ─────────────────────────────────────────────────────────────────────

STATE="$ADV/state.json"
rc=0
"$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>"$ADV/state.err" || rc=$?
case $rc in
  0) ;;
  3) die "advance: no state for #$ISSUE (nothing was claimed)" ;;
  6)
    bad=$(gh api "repos/$REPO/commits?path=issues/$ISSUE.json&sha=swarm/state&per_page=1" --jq '.[0].sha // "unknown"' 2>/dev/null)
    body=$(tmpf .md) || die "advance: no temp dir"
    {
      printf '🧭 **dispatch** · 🚧 blocked:perimeter — the state file issues/%s.json carries a missing or invalid signature (last commit %s). Nothing was recorded; a human restores the file (`git log swarm/state -- issues/%s.json`, `state.sh resign-all` after a key rotation) and types `/swarm resume`.\n' "$ISSUE" "${bad:-unknown}" "$ISSUE"
      marker died "key=$KEY" "run=$RUN_ID" "topic=signature"
    } > "$body"
    if existing=$(find_comment "$ISSUE" "$(marker_pred died "key=$KEY" "topic=signature")"); then
      edit_comment "$(printf '%s' "$existing" | jq -r .id)" "$body" || true
    else
      post_comment "$ISSUE" "$body" >/dev/null || true
    fi
    rm -f "$body"
    die "advance: state #$ISSUE has an invalid signature (G37) — blocked:perimeter" ;;
  *) die "advance: cannot read state #$ISSUE" ;;
esac
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
SD() { local v; v=$(S "$1"); printf '%s' "${v:-$2}"; }
reload() { "$SWARM_LIB/state.sh" read "$ISSUE" > "$STATE" 2>/dev/null || log "state re-read failed"; }

if [ -z "${CONFIG_JSON:-}" ] || [ ! -f "$CONFIG_JSON" ]; then
  if [ -f "$RUN_DIR/config.json" ]; then CONFIG_JSON="$RUN_DIR/config.json"
  else CONFIG_JSON=$("$SWARM_LIB/config.sh" load --out "$ADV/config.json" 2>>"$LOGF") || die "advance: config could not be loaded (G27)"
  fi
fi
export CONFIG_JSON
C() { jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null; }
P() { jq -r "$1 // empty" "$PIPELINE" 2>/dev/null; }
ARTIFACTS_DIR=$(C '.artifacts_dir'); ARTIFACTS_DIR=${ARTIFACTS_DIR:-docs/swarm}
DEFAULT=$(C '.default_branch'); DEFAULT=${DEFAULT:-main}

STATUS=$(S '.status')
STAGE=$(S '.stage')
CUR_KEY=$(S '.current.key')
CUR_RUN=$(S '.current.run_id')
CUR_ROLE=$(S '.current.role')
ATTEMPT=$(SD '.current.attempt' "${KEY##*:}")
BASE_SHA=$(S '.current.base_sha')
ACTIVITY_FROM=$(S '.current.activity_from')
BRANCH=$(S '.branch')
# reason=finalize runs in a new workflow run: the record, the handoff and the job minutes
# belong to the run that claimed the key (current.run_id), never to this run's id
if [ "${FINALIZE:-false}" = true ] && [ "$CUR_KEY" = "$KEY" ] && [ -n "$CUR_RUN" ] && [ "$CUR_RUN" != "$RUN_ID" ]; then
  log "finalize: run $RUN_ID finalises the record of run $CUR_RUN"
  RUN_ID=$CUR_RUN
  export RUN_ID
  RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"
fi
REC=$(jq -c --arg k "$KEY" --argjson r "$RUN_ID" '[(.dispatches // [])[] | select(.key == $k and .run_id == $r)] | last // empty' "$STATE")
REC_STATUS=$(printf '%s' "${REC:-{\}}" | jq -r '.status // empty')
# the record's stage, not state.stage: a merge that landed mid-run has moved the state to retro
REC_STAGE=$(printf '%s' "${REC:-{\}}" | jq -r '.stage // empty')
[ -n "$REC_STAGE" ] && STAGE=$REC_STAGE
ROLE_TOKEN=$(printf '%s' "${REC:-{\}}" | jq -r '.role // empty')
[ -n "$ROLE_TOKEN" ] || ROLE_TOKEN=$CUR_ROLE
ROLE=${ROLE_TOKEN%%:*}
LANE=""
[ "$ROLE_TOKEN" != "$ROLE" ] && LANE=${ROLE_TOKEN#*:}
ROLE_ENTRY=$(jq -c --arg r "$ROLE" '[.stages[].roles[] | select(.name == $r)] | first // empty' "$PIPELINE")
CLASS=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.class // "read"')
EMOJI=$(jq -r --arg r "$ROLE" '.emoji[$r] // "🧭"' "$PIPELINE")
PATHK=$(SD '.path' full)
JOB_RESULT=${RUN_WRITE_RESULT:-skipped}
[ "$CLASS" = read ] && JOB_RESULT=${RUN_READ_RESULT:-skipped}
if [ "$JOB_RESULT" = skipped ]; then
  for r in "${RUN_READ_RESULT:-}" "${RUN_WRITE_RESULT:-}"; do [ -n "$r" ] && [ "$r" != skipped ] && JOB_RESULT=$r; done
fi
HANDOFF=0
[ -f "$RESULT" ] && HANDOFF=1

# ── 2. unclaimed / cancelled-pending ────────────────────────────────────────────

if [ -z "$REC" ]; then
  log "no record for ($KEY, $RUN_ID) — this run never claimed the dispatch; nothing touched"
  exit 0
fi

# ── 3. idempotency ──────────────────────────────────────────────────────────────

case $REC_STATUS in
  finished|died|invalid|cancelled-pending|superseded)
    log "already finalised: record ($KEY, $RUN_ID) is $REC_STATUS"
    exit 0 ;;
esac
if [ "${RUN_ATTEMPT:-1}" -gt 1 ] && [ "${BEGIN_OUTCOME:-}" != success ] && [ "${FINALIZE:-false}" != true ]; then
  reply "$ISSUE" "run-$RUN_ID-attempt-$RUN_ATTEMPT" "GitHub re-runs are not supported for run jobs; use \`/swarm resume\`" >/dev/null || true
  log "re-run attempt $RUN_ATTEMPT of a run whose begin did not succeed — replied, nothing recorded"
  exit 0
fi

working_comment_id() {
  local pref=${WORKING_COMMENT_ID:-} id
  [ -n "$pref" ] || pref=$(printf '%s' "$REC" | jq -r '.comment_id // empty')
  [ -n "$pref" ] || pref=$(S '.current.comment_id')
  if existing=$(find_comment "$ISSUE" "$(marker_pred stage "key=$KEY")" "$pref"); then
    id=$(printf '%s' "$existing" | jq -r .id)
    printf '%s' "$id"
  fi
}
WCID=$(working_comment_id)
[ -n "$WCID" ] && printf '%s' "$WCID" > "$ADV/comment-id"

# put_comment <file>: edit the working comment, or post when it is gone
put_comment() {
  if [ -n "$WCID" ]; then
    edit_comment "$WCID" "$1" || log "could not edit comment $WCID"
  else
    WCID=$(post_comment "$ISSUE" "$1") || { log "could not post the stage comment"; WCID=""; }
    [ -n "$WCID" ] && printf '%s' "$WCID" > "$ADV/comment-id"
  fi
}

project_labels() {
  reload
  if [ -x "$SWARM_LIB/labels.sh" ]; then "$SWARM_LIB/labels.sh" project "$ISSUE" "$STATE" || log "labels.sh project failed"; fi
  "$SWARM_LIB/state.sh" sync-comment "$ISSUE" >/dev/null 2>&1 || log "state comment not re-rendered"
}

if [ "$CUR_KEY" != "$KEY" ] || [ "$CUR_RUN" != "$RUN_ID" ]; then
  log "current is ${CUR_KEY:--}/${CUR_RUN:--}, not $KEY/$RUN_ID — this run was superseded"
  "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-superseded --arg key "$KEY" --arg run_id "$RUN_ID" --arg by "a newer dispatch (${CUR_KEY:-none})" >/dev/null 2>&1 || true
  body=$(tmpf .md) || die "advance: no temp dir"
  "$SWARM_LIB/render.sh" stage-superseded "$body" --arg emoji "$EMOJI" --arg role "$ROLE_TOKEN" --arg event "${CUR_KEY:-a newer dispatch}" \
    --arg at "$(now)" --arg attempt "$ATTEMPT" --arg key "${CUR_KEY:-?}" \
    --arg marker "$(marker stage "stage=$STAGE" "role=$ROLE_TOKEN" "attempt=$ATTEMPT" "key=$KEY" "run=$RUN_ID" "status=superseded")" \
    && put_comment "$body"
  rm -f "$body"
  exit 0
fi

runaway_tripped() {
  local limit n
  limit=$(C '.limits.runaway_per_hour'); [ -n "$limit" ] || limit=$(P '.limits.runaway_per_hour'); limit=${limit:-10}
  n=$(jq -r --arg now "$(now)" '[(.dispatches // [])[] | select(.at != null) | select(((($now | fromdateiso8601) - (.at | fromdateiso8601))) < 3600)] | length' "$STATE")
  [ "${n:-0}" -ge "$limit" ]
}

if [ $HANDOFF -eq 0 ] && [ "${BEGIN_OUTCOME:-}" != success ] && [ "${FINALIZE:-false}" != true ] \
   && { [ "$JOB_RESULT" = cancelled ] || [ "$JOB_RESULT" = skipped ]; }; then
  log "the run job was $JOB_RESULT before it ran (no handoff) — the pending-slot rule: unclaim and re-queue $KEY"
  rc=0
  "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-unclaim --arg key "$KEY" --arg run_id "$RUN_ID" >/dev/null || rc=$?
  case $rc in
    0) ;;
    5) log "state moved on before the unclaim — nothing fired"; exit 0 ;;
    *) die "advance: cannot unclaim $KEY (state.sh exit $rc)" ;;
  esac
  body=$(tmpf .md) || die "advance: no temp dir"
  "$SWARM_LIB/render.sh" stage-requeued "$body" --arg emoji "$EMOJI" --arg role "$ROLE_TOKEN" --arg attempt "$ATTEMPT" --arg run_id "$RUN_ID" \
    --arg at "$(now)" --arg key "$KEY" \
    --arg marker "$(marker stage "stage=$STAGE" "role=$ROLE_TOKEN" "attempt=$ATTEMPT" "key=$KEY" "run=$RUN_ID" "status=requeued")" \
    && put_comment "$body"
  rm -f "$body"
  reload
  if runaway_tripped; then
    "$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason runaway --arg detail "re-queue of $KEY refused: dispatches in the last hour reached the runaway limit" >/dev/null || true
    project_labels
    exit 0
  fi
  "$SWARM_LIB/fire.sh" "$ISSUE" "$STAGE" "$ROLE_TOKEN" "$KEY" retry >/dev/null || rc=$?
  project_labels
  exit $rc
fi

# ── 4. stats, authoritative validation, classification ──────────────────────────

find_exec() { # <env value> <names…> → the first existing file
  local f
  [ -n "$1" ] && [ -f "$1" ] && { printf '%s' "$1"; return; }
  shift
  for f in "$@"; do [ -f "$f" ] && { printf '%s' "$f"; return; }; done
}
EXEC_FILE=$(find_exec "${EXEC:-}" "$RUN_DIR/audit/execution.json.gz" "$RUN_DIR/execution.json.gz" "$RUN_DIR/execution.json" "$RUN_DIR/audit/execution.json")
RETRY_FILE=$(find_exec "${RETRY_EXEC:-}" "$RUN_DIR/audit/retry-execution.json.gz" "$RUN_DIR/retry-execution.json.gz")
CRITIC_EXEC_FILE=$(find_exec "${CRITIC_EXEC:-}" "$RUN_DIR/critic/critic-execution.json.gz" "$RUN_DIR/critic/critic-execution.json" "$RUN_DIR/audit/critic-execution.json.gz")
STATS=$("$SWARM_LIB/exec-stats.sh" "${EXEC_FILE:-/nonexistent}" 2>/dev/null) || STATS='{"present":false}'
RSTATS='{"present":false}'
[ -n "$RETRY_FILE" ] && RSTATS=$("$SWARM_LIB/exec-stats.sh" "$RETRY_FILE" 2>/dev/null)
printf '%s' "$STATS" > "$ADV/exec-stats.json"

git_ok=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git_ok=1
PUSHED=""
if [ $git_ok -eq 1 ] && [ -n "$BRANCH" ]; then
  git fetch -q origin "$BRANCH" >/dev/null 2>&1 || git fetch -q origin >/dev/null 2>&1 || true
  PUSHED=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null) || PUSHED=""
  # the authoritative checks read the tree the role left on the branch, never the default branch
  if [ -n "$PUSHED" ]; then git checkout -q --detach "$PUSHED" 2>/dev/null || log "cannot check out $PUSHED"; fi
fi

# a GitHub re-run of a failed advance (blocked:stalled, current untouched) reopens the dispatch first
if [ "$STATUS" = blocked ] && [ "$(S '.blocked.reason')" = stalled ]; then
  "$SWARM_LIB/state.sh" write "$ISSUE" resume --arg mode finalize --arg note "advance re-run $RUN_ID" >/dev/null 2>>"$LOGF" \
    && { log "blocked:stalled reopened for this re-run"; reload; STATUS=$(S '.status'); } || log "could not reopen blocked:stalled (state.sh exit $?)"
fi

# pending entries the pushed head already carries are cleared before the checks (V7 /
# V14 read the state) — landing is content-keyed, so nothing is lost when the head lacks one
PENDING_LEFT=()
if [ "$CLASS" = write ] && [ -n "$PUSHED" ] && [ "$PUSHED" != "$BASE_SHA" ]; then
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    if git cat-file -e "$PUSHED:$ARTIFACTS_DIR/$ISSUE/$pf" 2>/dev/null; then
      "$SWARM_LIB/state.sh" clear-pending "$ISSUE" "$pf" >/dev/null 2>>"$LOGF" && log "pending $pf is on ${PUSHED:0:12} — cleared" || log "clear-pending $pf failed"
    else
      PENDING_LEFT+=("$pf")
    fi
  done < <(S '.pending_artifacts[].file')
  reload
fi

VALIDATION="$ADV/validation.json"
ROLE=$ROLE_TOKEN LANE=$LANE CLASS=$CLASS STAGE=$STAGE ISSUE=$ISSUE ATTEMPT=$ATTEMPT EXEC=${EXEC_FILE:-} BRANCH=$BRANCH BASE_SHA=$BASE_SHA \
  ARTIFACTS_DIR=$ARTIFACTS_DIR OWNER_REPO=$REPO STATE_JSON=$STATE CONFIG_JSON=$CONFIG_JSON RUN_DIR=$RUN_DIR VALIDATION_OUT=$VALIDATION \
  GITHUB_OUTPUT=/dev/null "$SWARM_LIB/validate-result.sh" --authoritative >> "$LOGF" 2>&1
VALID_OK=false
[ -f "$VALIDATION" ] && VALID_OK=$(jq -r '.ok // false' "$VALIDATION")
ERRORS=$(jq -c '.errors // []' "$VALIDATION" 2>/dev/null || printf '[]')
if [ "$VALID_OK" = true ]; then
  log "authoritative validation: ok"
else
  log "authoritative validation: $(printf '%s' "$ERRORS" | jq -r 'map("\(.check): \(.msg)") | join("; ")' | head -c 600)"
fi
if [ "${VALID:-}" = true ] && [ "$VALID_OK" != true ]; then log "the run job's own validation said ok; the authoritative pass disagrees — the authoritative verdict counts"; fi

OUTCOME=""
DIED_REASON=""
VERDICT=""
if [ "$VALID_OK" = true ]; then
  OUTCOME=finished
  VERDICT=$(jq -r '.verdict // empty' "$RESULT")
  [ -n "$VERDICT" ] || { OUTCOME=invalid; ERRORS=$(printf '%s' "$ERRORS" | jq -c '. + [{check: "schema", msg: "no verdict"}]'); }
elif [ "$JOB_RESULT" = failure ] || [ "$JOB_RESULT" = cancelled ] || { [ -n "${ROLE_OUTCOME:-}" ] && [ "$ROLE_OUTCOME" != success ]; }; then
  OUTCOME=died
else
  OUTCOME=invalid
fi

classify_death() {
  local logtxt cap turns reason step_secs timeout
  logtxt=$(gh run view -R "$REPO" "$RUN_ID" --log-failed 2>/dev/null | tail -c 20000)
  cap=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.turns // 0')
  turns=$(printf '%s' "$STATS" | jq -r '.num_turns // 0')
  reason=$(printf '%s' "$STATS" | jq -r '.terminal_reason // empty')
  timeout=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.timeout // 0')
  step_secs=$(gh run view -R "$REPO" "$RUN_ID" --json jobs --jq '[.jobs[]? | select(.name | test("^run-")) | (.steps // [])[]? | select(.startedAt != null and .completedAt != null) | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))] | max // 0' 2>/dev/null)
  step_secs=${step_secs:-0}
  if [ "$reason" = max-turns ] || { [ "$cap" -gt 0 ] && [ "${turns%%.*}" -ge "$cap" ]; }; then printf 'max-turns'; return; fi
  # the job itself was cancelled after it started (the never-started case is the
  # pending-slot rule above); a step killed by timeout-minutes reports failure, not cancelled
  if [ "$JOB_RESULT" = cancelled ]; then printf 'cancelled'; return; fi
  if printf '%s' "$logtxt" | grep -qiE '(^|[^0-9])401([^0-9]|$)|authentication_error|invalid.*token|OAuth token.*expired'; then printf 'auth'; return; fi
  if printf '%s' "$logtxt" | grep -qiE 'usage limit|rate limit|(^|[^0-9])429([^0-9]|$)|overloaded'; then printf 'ratelimit'; return; fi
  if [ "${ROLE_OUTCOME:-}" = cancelled ]; then printf 'timeout'; return; fi
  # timeout = the step ended in failure with no result record and ran for (about) its whole
  # timeout-minutes: the execution file is written only when the SDK query returns
  if [ "$(printf '%s' "$STATS" | jq -r '.has_result // false')" != true ] && [ "$timeout" -gt 0 ] && [ "${step_secs%%.*}" -ge $((timeout * 60 - 15)) ]; then printf 'timeout'; return; fi
  if printf '%s' "$logtxt" | grep -qiE 'timed out|exceeded the maximum execution time'; then printf 'timeout'; return; fi
  printf 'error'
}
[ "$OUTCOME" = died ] && DIED_REASON=$(classify_death)
log "outcome: $OUTCOME${VERDICT:+ $VERDICT}${DIED_REASON:+ ($DIED_REASON)}"

# ── 5. critic acceptance ────────────────────────────────────────────────────────

CRITIC_OUT="$ADV/critic.json"
critic_cfg=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -c '.critic | if type == "object" then . else empty end')
CRITIC_CONFIGURED=0
if [ -n "$critic_cfg" ] && [ "$(printf '%s' "$critic_cfg" | jq -r '.enabled // true')" = true ]; then
  if [ "$PATHK" = full ] || [ "$(printf '%s' "$critic_cfg" | jq -r '.on_short // "skip"')" = run ]; then CRITIC_CONFIGURED=1; fi
fi
CRITIC_JSON="{}"
CRITIC_FILE=""
if [ $CRITIC_CONFIGURED -eq 1 ] && [ "$OUTCOME" = finished ]; then
  cf="$RUN_DIR/critic/critic.json"
  [ -f "$cf" ] || cf="$RUN_DIR/critic.json"
  err=""
  if [ "${CRITIC_RESULT:-}" = failure ] || [ "${CRITIC_RESULT:-}" = cancelled ]; then err="critic job $CRITIC_RESULT"
  elif [ ! -f "$cf" ]; then err="no critic.json"
  elif ! jq -e 'type == "object"' "$cf" >/dev/null 2>&1; then err="critic.json is not valid JSON"
  elif [ -z "$CRITIC_EXEC_FILE" ]; then err="no critic execution file — not written by the critic"
  else
    cstats=$("$SWARM_LIB/exec-stats.sh" "$CRITIC_EXEC_FILE" 2>/dev/null) || cstats='{"present":false}'
    if ! printf '%s' "$cstats" | jq -e '.present == true and ((.wrote_paths // []) | any(endswith(".swarm-run/critic.json") or . == "critic.json" or . == ".swarm-run/critic.json"))' >/dev/null 2>&1; then
      err="not written by the critic"
    elif ! jq -e --arg k "$KEY" '.v == 2 and (.score | type == "number") and (.threshold | type == "number") and (.verdict | IN("pass", "fail")) and .target_key == $k' "$cf" >/dev/null 2>&1; then
      err="critic.json does not match the schema or this key"
    fi
  fi
  if [ -z "$err" ]; then
    CRITIC_FILE=$cf
    CRITIC_JSON=$(jq -c '{accepted: true, rubric, score, threshold, verdict, confidence: (.confidence // "medium"), findings: (.findings // []), model}' "$cf")
    log "critic accepted: $(printf '%s' "$CRITIC_JSON" | jq -r '"\(.rubric) \(.score)/\(.threshold) \(.verdict) (\(.confidence))"')"
  else
    CRITIC_JSON=$(jq -cn --arg e "$err" --arg r "$(printf '%s' "$critic_cfg" | jq -r '.rubric // "generic"')" '{accepted: false, error: $e, rubric: $r}')
    log "critic not accepted: $err"
  fi
fi
printf '%s' "$CRITIC_JSON" > "$CRITIC_OUT"

# ── 6. G32 model map, G29 perimeter ─────────────────────────────────────────────

WARN=()
PERIM=()
MODEL_REQ=$(printf '%s' "$REC" | jq -r '.model_requested // empty')
[ -n "$MODEL_REQ" ] || MODEL_REQ=${MODEL:-}
[ -n "$MODEL_REQ" ] || MODEL_REQ=$(jq -r --arg t "$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.tier // "default"')" '.models.tiers[$t] // empty' "$PIPELINE")
MODEL_ACT=$(printf '%s' "$STATS" | jq -r '.model_actual // empty')
MODEL_BLOCK=0
if [ -n "$MODEL_ACT" ] && [ -n "$MODEL_REQ" ] && [ "$MODEL_ACT" != "$MODEL_REQ" ]; then
  if [ "$(C '.require_model_map')" = true ]; then
    MODEL_BLOCK=1
    WARN+=("model map not honoured: requested $MODEL_REQ, ran $MODEL_ACT — blocked:model (require_model_map)")
  else
    WARN+=("model map not honoured: requested $MODEL_REQ, ran $MODEL_ACT — review is by instance, not by model")
  fi
fi

mapfile -t PROTECTED < <({ jq -r '.protected_paths[]?' "$PIPELINE"; C '.protected_paths[]'; } | sed '/^$/d' | LC_ALL=C sort -u)
if [ "$CLASS" = write ] && [ $git_ok -eq 1 ] && [ -n "$PUSHED" ] && [ -n "$BASE_SHA" ] && [ "$PUSHED" != "$BASE_SHA" ]; then
  if ! git merge-base --is-ancestor "$BASE_SHA" "$PUSHED" 2>/dev/null; then
    PERIM+=("history rewritten: base ${BASE_SHA:0:12} is no longer an ancestor of origin/$BRANCH (${PUSHED:0:12}); restore it with git push --force-with-lease origin ${BASE_SHA:0:12}:$BRANCH after reading the new history")
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if matches_glob "$f" "${PROTECTED[@]}"; then PERIM+=("protected path changed: $f"); fi
    done < <(git diff --name-only "$BASE_SHA...$PUSHED" 2>/dev/null)
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      PERIM+=("CI gate configuration changed in $l")
    done < <("$SWARM_LIB/perimeter.sh" manifests "$BASE_SHA" "$PUSHED" 2>>"$LOGF")
    if [ ${#PERIM[@]} -gt 0 ]; then PERIM+=("the diff is left in place; a human reverts it (git revert of the commits in ${BASE_SHA:0:12}..${PUSHED:0:12} on $BRANCH)"); fi
  fi
fi
if [ "$CLASS" = write ] && [ -n "$ACTIVITY_FROM" ] && [ -n "$BRANCH" ]; then
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    PERIM+=("repository activity outside the branch: $l (git push --delete origin <ref>, or git revert, by a human)")
  done < <(REFS_SNAPSHOT="$RUN_DIR/refs-snapshot.txt" "$SWARM_LIB/perimeter.sh" activity "$ACTIVITY_FROM" "$BRANCH" 2>>"$LOGF")
fi
if [ "$CLASS" = read ]; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    PERIM+=("read-class run: $m")
  done < <(printf '%s' "$ERRORS" | jq -r '.[] | select(.check == "V18") | .msg')
fi
[ ${#PERIM[@]} -gt 0 ] && log "perimeter: $(printf '%s; ' "${PERIM[@]}")"

# ── 7. the record ───────────────────────────────────────────────────────────────

# gh's --jq takes no --arg: the raw jobs JSON is reduced locally (a job still running —
# this one — is measured up to now)
MINUTES=$(gh run view -R "$REPO" "$RUN_ID" --json jobs 2>/dev/null | jq -c --arg now "$(now)" '
  [ .jobs[]? | select(.startedAt != null)
    | {name, m: (((((.completedAt // $now) | fromdateiso8601) - (.startedAt | fromdateiso8601)) / 60) | ceil)} ]
  | {role: ([.[] | select(.name | test("^run-")) | .m] | add // 0), overhead: ([.[] | select(.name | test("^run-") | not) | .m] | add // 0)}' 2>/dev/null)
[ -n "$MINUTES" ] && printf '%s' "$MINUTES" | jq -e . >/dev/null 2>&1 || MINUTES='{"role":0,"overhead":0}'
RETRY_RAN=0
[ -n "${RETRY_OUTCOME:-}" ] && [ "$RETRY_OUTCOME" != skipped ] && RETRY_RAN=1
AUDIT_NAME="swarm-$ISSUE-$STAGE-$(printf '%s' "$ROLE_TOKEN" | tr ':' '-')-a$ATTEMPT-$RUN_ID"
# actions/upload-artifact rejects ':' in names: the key appears with ':' → '-' (dispatch.yml `names` step)
HANDOFF_NAME="swarm-run-$(printf '%s' "$KEY" | tr ':' '-')-$RUN_ID"
HEAD_REC=""
if [ "$CLASS" = write ] && [ "$OUTCOME" = finished ] && [ "$VERDICT" = pass ] && [ -n "$PUSHED" ]; then HEAD_REC=$PUSHED; fi
STATS_ARG=$(jq -cn --argjson s "$STATS" --argjson r "$RSTATS" --argjson m "$MINUTES" --arg mreq "$MODEL_REQ" --arg head "$HEAD_REC" \
  --arg audit "$AUDIT_NAME" --arg handoff "$HANDOFF_NAME" --argjson retry "$RETRY_RAN" --argjson v "$(jq -c '{ok, errors}' "$VALIDATION" 2>/dev/null || printf '{"ok":false,"errors":[]}')" \
  --argjson critic "$CRITIC_JSON" --arg base "$BASE_SHA" --arg ra "$RUN_ATTEMPT" '
  { cost_usd: ((($s.total_cost_usd // 0) + ($r.total_cost_usd // 0)) * 10000 | round / 10000),
    turns: (($s.num_turns // 0) + ($r.num_turns // 0)),
    duration_s: (($s.duration_s // 0) + ($r.duration_s // 0)),
    job_minutes: ($m.role // 0), overhead_minutes: ($m.overhead // 0),
    model_requested: (if $mreq == "" then null else $mreq end), model_actual: ($s.model_actual // null),
    retry: $retry, head: (if $head == "" then null else $head end), artifact: $audit, handoff: $handoff,
    validation: $v, last_text: ($s.last_text // null), run_attempt: ($ra | tonumber), base_sha: (if $base == "" then null else $base end),
    critic: (if $critic.accepted == true then {score: $critic.score, threshold: $critic.threshold, verdict: $critic.verdict, confidence: $critic.confidence, rubric: $critic.rubric}
             elif ($critic.error // "") != "" then {error: $critic.error} else null end) }')

rc=0
case $OUTCOME in
  finished) "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-finished --arg key "$KEY" --arg run_id "$RUN_ID" --arg verdict "$VERDICT" --argjson stats "$STATS_ARG" >/dev/null || rc=$? ;;
  died) "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-died --arg key "$KEY" --arg run_id "$RUN_ID" --arg died_reason "$DIED_REASON" --argjson stats "$STATS_ARG" >/dev/null || rc=$? ;;
  invalid) "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-invalid --arg key "$KEY" --arg run_id "$RUN_ID" --argjson stats "$STATS_ARG" >/dev/null || rc=$? ;;
esac
case $rc in
  0) log "recorded dispatch-$OUTCOME for ($KEY, $RUN_ID)" ;;
  5) log "state moved on: dispatch-$OUTCOME refused (record or current changed) — nothing else touched"; exit 0 ;;
  *) die "advance: cannot record dispatch-$OUTCOME (state.sh exit $rc)" ;;
esac
reload
STATUS=$(S '.status')

# ── 8. artifacts, pending, PR ───────────────────────────────────────────────────

FACTS="$ADV/facts.json"
printf '{}' > "$FACTS"
ART_LINES="[]"
NOTE_ARTIFACTS=()
if [ "$OUTCOME" = finished ]; then
  # the PR a write role opened — recorded first, so the artifacts are staged, never pushed, from here on
  if [ "$CLASS" = write ] && [ -z "$(S '.pr')" ] && [ -n "$BRANCH" ]; then
    prn=$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
    if [ -n "$prn" ]; then
      "$SWARM_LIB/state.sh" write "$ISSUE" pr-opened --arg pr "$prn" --arg branch "$BRANCH" ${HEAD_REC:+--arg head "$HEAD_REC"} >/dev/null 2>>"$LOGF" && log "PR #$prn recorded" || log "pr-opened not recorded"
      jq -c --arg p "$prn" '. + {pr: $p}' "$FACTS" > "$FACTS.tmp" && mv "$FACTS.tmp" "$FACTS"
      reload
    fi
  fi
  outf=$(tmpf .out) || die "advance: no temp dir"
  rubric=""
  [ -n "$CRITIC_FILE" ] && rubric=$(printf '%s' "$CRITIC_JSON" | jq -r '.rubric // empty')
  crc=0
  GITHUB_OUTPUT=$outf CRITIC_JSON=$CRITIC_FILE HEAD=$PUSHED ARTIFACTS_SRC="$RUN_DIR/artifacts" \
    STAGE_NOTHING=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r 'if .lands_pending == true then 1 else 0 end') \
    "$SWARM_LIB/commit-artifacts.sh" "$ISSUE" "$STATE" ${rubric:+--rubric "$rubric"} >> "$LOGF" 2>&1 || crc=$?
  mode=$(sed -n 's/^mode=//p' "$outf" | head -1)
  landed=$(sed -n 's/^landed=//p' "$outf" | head -1)
  staged=$(sed -n 's/^staged=//p' "$outf" | head -1)
  cbranch=$(sed -n 's/^branch=//p' "$outf" | head -1)
  rm -f "$outf"
  [ $crc -eq 0 ] || WARN+=("artifacts could not be ${mode:-landed} (commit-artifacts.sh exit $crc) — see the advance log")
  if [ -n "$cbranch" ] && [ "$cbranch" != "$BRANCH" ]; then
    BRANCH=$cbranch
    jq -c --arg b "$BRANCH" '. + {branch: $b}' "$FACTS" > "$FACTS.tmp" && mv "$FACTS.tmp" "$FACTS"
  fi
  for f in $landed; do
    case $mode in
      commit) ART_LINES=$(printf '%s' "$ART_LINES" | jq -c --arg p "$ARTIFACTS_DIR/$ISSUE/$f" '. + [{path: $p, status: "landed"}]') ;;
      *) ART_LINES=$(printf '%s' "$ART_LINES" | jq -c --arg p "$ARTIFACTS_DIR/$ISSUE/$f" '. + [{path: $p, status: "landed"}]') ;;
    esac
  done
  for f in $staged; do ART_LINES=$(printf '%s' "$ART_LINES" | jq -c --arg p "$ARTIFACTS_DIR/$ISSUE/$f" '. + [{path: $p, status: "staged"}]'); done
  # what is still pending after this write attempt is said, and kept for upload
  for pf in "${PENDING_LEFT[@]}"; do
    NOTE_ARTIFACTS+=("$pf still pending (not on ${PUSHED:0:12}); it lands with the next write role")
    mkdir -p "$ADV/pending-upload/$(dirname "$pf")"
    [ -f "$RUN_DIR/pending/$pf" ] && cp "$RUN_DIR/pending/$pf" "$ADV/pending-upload/$pf"
  done
  [ -n "$HEAD_REC" ] && { jq -c --arg h "$HEAD_REC" '. + {head: $h}' "$FACTS" > "$FACTS.tmp" && mv "$FACTS.tmp" "$FACTS"; }
  reload
fi

# ── 9. the final comment ────────────────────────────────────────────────────────

comment_input() { # <verdict word> <next text>
  jq -cn --arg emoji "$EMOJI" --arg role "$ROLE_TOKEN" --arg verdict "$1" --argjson st "$STATS_ARG" --arg next "$2" \
    --argjson result "$( [ -f "$RESULT" ] && jq -c . "$RESULT" 2>/dev/null || printf '{}')" --argjson art "$ART_LINES" \
    --arg head "${HEAD_REC:-$PUSHED}" --arg pr "$(S '.pr')" --arg audit "$AUDIT_NAME" --argjson errors "$ERRORS" \
    --argjson exec "$STATS" --arg rs "$(SD '.rework.spent' 0)" --arg rb "$(SD '.rework.budget' 5)" \
    --arg marker "$(marker stage "stage=$STAGE" "role=$ROLE_TOKEN" "attempt=$ATTEMPT" "key=$KEY" "run=$RUN_ID" "status=$3" ${VERDICT:+"verdict=$VERDICT"} ${HEAD_REC:+"head=$HEAD_REC"} ${MODEL_ACT:+"model=$MODEL_ACT"})" \
    --args '
    { emoji: $emoji, role: $role, verdict: $verdict,
      model: ($st.model_actual // $st.model_requested), cost_usd: $st.cost_usd, turns: $st.turns, duration_s: $st.duration_s, job_minutes: $st.job_minutes,
      rework_spent: ($rs | tonumber), rework_budget: ($rb | tonumber),
      summary: ($result.summary // null), evidence: ($result.evidence // []), artifacts: $art,
      head: (if $head == "" then null else $head end), pr: (if $pr == "" then null else ($pr | tonumber) end), audit: $audit,
      not_covered: ($result.not_covered // []), next: (if $next == "" then null else $next end),
      warnings: $ARGS.positional, errors: (if $verdict == "invalid" then $errors else [] end),
      permission_denials: ($exec.permission_denials_list // []), marker: $marker }' "${WARN[@]}" "${NOTE_ARTIFACTS[@]}"
}

block_now() { # <reason> <detail>
  local brc=0
  "$SWARM_LIB/state.sh" write "$ISSUE" block --arg reason "$1" --arg detail "$2" --arg from_key "$KEY" >/dev/null || brc=$?
  [ $brc -eq 0 ] || log "block $1 not recorded (state.sh exit $brc)"
}

COMMENT_IN="$ADV/comment.json"
body=$(tmpf .md) || die "advance: no temp dir"
case $OUTCOME in
  finished)
    if [ ${#PERIM[@]} -gt 0 ]; then
      detail=$(printf '%s; ' "${PERIM[@]}" | head -c 600)
      block_now perimeter "$detail"
      WARN+=("${PERIM[@]}")
      comment_input "$VERDICT" "blocked:perimeter — the offending change is left in place and named above; a human reverts it, then /swarm resume" finished > "$COMMENT_IN"
    elif [ $MODEL_BLOCK -eq 1 ]; then
      block_now model "requested $MODEL_REQ, ran $MODEL_ACT (require_model_map)"
      comment_input "$VERDICT" "blocked:model — set require_model_map: false or fix the model map, then /swarm resume" finished > "$COMMENT_IN"
    else
      comment_input "$VERDICT" "routing…" finished > "$COMMENT_IN"
    fi
    "$SWARM_LIB/render.sh" comment "$COMMENT_IN" "$body" --arg repo "$REPO" && put_comment "$body" ;;
  invalid)
    if [ ${#PERIM[@]} -gt 0 ]; then
      block_now perimeter "$(printf '%s; ' "${PERIM[@]}" | head -c 600)"
      WARN+=("${PERIM[@]}")
      comment_input invalid "blocked:perimeter — the offending change is left in place and named above; a human reverts it, then /swarm resume" invalid > "$COMMENT_IN"
    else
      if [ "$STATUS" = routing ]; then
        block_now agent-output "result.json invalid after the retry: $(printf '%s' "$ERRORS" | jq -r 'map(.check) | unique | join(", ")')"
      fi
      comment_input invalid "blocked:agent-output — the validator errors are listed above (audit $AUDIT_NAME); /swarm resume re-runs $ROLE_TOKEN at attempt $((ATTEMPT + 1))" invalid > "$COMMENT_IN"
    fi
    "$SWARM_LIB/render.sh" comment "$COMMENT_IN" "$body" --arg repo "$REPO" && put_comment "$body" ;;
  died)
    cause=$DIED_REASON
    advice=""
    details="$(printf '%s' "$STATS" | jq -r '.last_text // ""' | head -c 500)"
    marker_line=$(marker stage "stage=$STAGE" "role=$ROLE_TOKEN" "attempt=$ATTEMPT" "key=$KEY" "run=$RUN_ID" "status=died")
    if [ "$STATUS" != routing ]; then
      advice="recorded; the issue is $STATUS, nothing fired"
      "$SWARM_LIB/render.sh" died "$body" --arg role "$ROLE_TOKEN" --arg cause "$cause" --arg advice "$advice" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --sarg details "$details" --arg marker "$marker_line" && put_comment "$body"
    else
      case $cause in
        max-turns|error)
          if [ "$ATTEMPT" -le 1 ]; then
            rc=0
            "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-queued --arg stage "$STAGE" --arg role "$ROLE_TOKEN" --arg reason retry --arg from_key "$KEY" --arg model "$MODEL_REQ" >/dev/null || rc=$?
            if [ $rc -eq 0 ]; then
              reload
              nk=$(S '.next.key')
              advice="retrying automatically once as $nk"
              "$SWARM_LIB/render.sh" died "$body" --arg role "$ROLE_TOKEN" --arg cause "$cause" --arg advice "$advice" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --sarg details "$details" --arg marker "$marker_line" && put_comment "$body"
              if runaway_tripped; then
                block_now runaway "automatic retry of $KEY refused: dispatches in the last hour reached the runaway limit"
              else
                "$SWARM_LIB/fire.sh" "$ISSUE" "$STAGE" "$ROLE_TOKEN" "$nk" retry >/dev/null || rc=$?
              fi
            else
              log "retry could not be queued (state.sh exit $rc)"
            fi
          else
            block_now agent-output "run died ($cause) at attempt $ATTEMPT"
            advice="/swarm resume to retry at attempt $((ATTEMPT + 1))"
            "$SWARM_LIB/render.sh" died "$body" --arg role "$ROLE_TOKEN" --arg cause "$cause" --arg advice "$advice" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --sarg details "$details" --arg marker "$marker_line" && put_comment "$body"
          fi ;;
        ratelimit)
          backoff=$(C '.limits.ratelimit_backoff_minutes'); [ -n "$backoff" ] || backoff=$(P '.limits.ratelimit_backoff_minutes'); backoff=${backoff:-180}
          not_before=$(jq -rn --arg t "$(now)" --arg m "$backoff" '$t | fromdateiso8601 + (($m | tonumber) * 60) | todateiso8601')
          rc=0
          "$SWARM_LIB/state.sh" write "$ISSUE" dispatch-queued --arg stage "$STAGE" --arg role "$ROLE_TOKEN" --arg reason retry --arg from_key "$KEY" --arg model "$MODEL_REQ" --arg not_before "$not_before" >/dev/null || rc=$?
          [ $rc -eq 0 ] || log "ratelimit back-off could not be queued (state.sh exit $rc)"
          "$SWARM_LIB/render.sh" ratelimit "$body" --arg role "$ROLE_TOKEN" --arg not_before "$not_before" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --arg marker "$marker_line" && put_comment "$body" ;;
        auth)
          block_now auth "CLAUDE_CODE_OAUTH_TOKEN rejected (run $RUN_ID)"
          advice="renew CLAUDE_CODE_OAUTH_TOKEN: claude setup-token && gh secret set CLAUDE_CODE_OAUTH_TOKEN, then /swarm resume"
          "$SWARM_LIB/render.sh" died "$body" --arg role "$ROLE_TOKEN" --arg cause "$cause" --arg advice "$advice" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --sarg details "$details" --arg marker "$marker_line" && put_comment "$body" ;;
        *)
          block_now agent-output "run died ($cause)"
          advice="/swarm resume to retry at attempt $((ATTEMPT + 1))"
          cause_text=$cause
          [ "$cause" = timeout ] && cause_text="timeout after $(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.timeout // "?"')m"
          "$SWARM_LIB/render.sh" died "$body" --arg role "$ROLE_TOKEN" --arg cause "$cause_text" --arg advice "$advice" --arg attempt "$ATTEMPT" --arg run_url "$RUN_URL" --sarg details "$details" --arg marker "$marker_line" && put_comment "$body" ;;
      esac
    fi ;;
esac
rm -f "$body"
project_labels

# ── 10. routing ─────────────────────────────────────────────────────────────────

if [ "$OUTCOME" = finished ]; then
  case $(S '.status') in
    blocked) log "status is blocked:$(S '.blocked.reason') after the record — nothing routed" ;;
    *) "$SWARM_LIB/route.sh" "$ISSUE" "$KEY" "$RUN_ID" || die "advance: route.sh failed (exit $?)" ;;
  esac
fi
log "advance done"
exit 0
