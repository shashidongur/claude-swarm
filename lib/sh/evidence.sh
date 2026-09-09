#!/usr/bin/env bash
# evidence.sh — evidence workflows: fire, wait, collect (spec §10.1, §9.3, §4.5).
#
#   evidence.sh fire <issue> <slot> <head> <key> [<consumer>] [--arg k v …]
#       (extra --arg pairs are routing facts folded into the evidence-fired CAS:
#       --arg stage <the stage being entered>, --arg done_stage, --arg done_lane …)
#       Fires the project's evidence workflow for the slot (`test` / `security`: the
#       workflow name comes from config `evidence.<slot>`) on <head>, claim-first:
#       `evidence-fired` counts the fire against `limits.evidence_fires_per_issue`
#       inside the CAS (G39), then `gh workflow run <file> --ref <default> -f issue -f ref
#       -f key`, verify by the key at the end of the run-name (as fire.sh), then
#       `evidence-run` records the run id. <key> is the wait key from
#       `state.sh next-key <state.json> <stage> evidence`; <consumer> defaults to the
#       first role of the stage whose `evidence_before.workflow` is the slot.
#       Skips (exit 0, nothing fired, a synthetic manifest under
#       $EVIDENCE_DIR/<slot>/manifest.json whose section carries the reason, outputs
#       evidence_fired=false evidence_reason=<reason>):
#         · G39  fires[slot] ≥ cap          → "evidence fire cap reached (N); CI evidence only"
#         · G31  SWARM_MONTHLY_BRAKE=<text> → "monthly budget: <text>; evidence not run"
#       Refuses (exit 9, nothing written): SWARM_EVIDENCE_PERIMETER=<text> — G29(f), the
#       caller determined the branch diff touches .github/** and blocks the issue itself.
#       A fire with no verified run: `block fire` + fire-failed comment, exit 1.
#       Outputs: evidence_fired, evidence_reason, evidence_run_id, evidence_key, evidence_workflow.
#
#   evidence.sh wait <slot> <head> <consumer>
#       Before waiting for CI (slot `ci`; event pull_request when state.pr is set, else
#       push): (a) consults evidence.seen[head][name][event]; (b) asks GitHub
#       `actions/runs?head_sha=<head>&event=<event>` filtered by workflow name — a
#       completed run is recorded with `evidence-seen` and consumed at once; an in-flight
#       one is recorded in `evidence.pending.run_id` (`evidence-pending`, status →
#       evidence); nothing known → `evidence-pending` with run_id 0. Exit 0 always;
#       outputs evidence_status=complete|pending, evidence_conclusion, evidence_run_id,
#       evidence_url, evidence_event, evidence_key.
#
#   evidence.sh collect <issue> <head> [<dir>]
#       Downloads every run recorded in evidence.seen[head] into <dir>/<workflow dir>/
#       (`gh run download`; dir = `CI` for the ci slot, the slot for the others, the
#       name otherwise — the same rule as begin.sh) and writes <dir>/index.json
#       {"<dir>": {workflow, run_id, conclusion, head, url, artifact: ok|missing|skipped}}.
#       A missing artifact or manifest gets a synthetic manifest.json with every section
#       `{ran: false, reason: "artifact missing"}` so the role must say so (V17).
#       Existing synthetic manifests (a skipped fire) are kept and indexed as `skipped`.
#       A red run's failed-job log tail lands in failed.log. Exit 0; outputs evidence.
#
# Environment: REPO, ISSUE (wait), RUN_ID, SWARM_STATE_KEY, CONFIG_JSON (evidence names,
# default branch, limits), GH_TOKEN; EVIDENCE_DIR (default .swarm-run/evidence);
# SWARM_FIRE_SLEEP (poll interval; the harness sets 0).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

EVIDENCE_DIR=${EVIDENCE_DIR:-.swarm-run/evidence}
POLL=${SWARM_FIRE_SLEEP:-5}
POLLS=12

cfg() { # <jq path> [default]
  local v=""
  if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then
    v=$(jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null)
  fi
  printf '%s\n' "${v:-${2:-}}"
}

# slot_name <slot> → the configured workflow name (the slot itself when unconfigured)
slot_name() { cfg ".evidence[\"$1\"]" "$1"; }

# name_slot <name> → the slot for a workflow name (empty when none)
name_slot() {
  [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ] || { printf '\n'; return; }
  jq -r --arg n "$1" '(.evidence // {}) | to_entries[] | select(.value == $n) | .key' "$CONFIG_JSON" 2>/dev/null | head -1
}

# evidence_dir <workflow name> → the directory name (§10.6; begin.sh's rule)
evidence_dir() {
  local slot
  slot=$(name_slot "$1")
  case $slot in
    ci) printf 'CI\n' ;;
    "") printf '%s\n' "$1" | tr -c 'A-Za-z0-9_.-\n' '_' ;;
    *) printf '%s\n' "$slot" ;;
  esac
}

synthetic_manifest() { # <dir> <reason> [<issue>] [<head>] [<key>]
  mkdir -p "$1"
  jq -n --arg reason "$2" --arg at "$(now)" --argjson issue "${3:-0}" --arg ref "${4:-}" --arg key "${5:-}" \
    '{v: 2, issue: $issue, synthetic: true, produced_at: $at, sections: {all: {ran: false, reason: $reason}}}
     + (if $ref != "" then {ref: $ref} else {} end) + (if $key != "" then {key: $key} else {} end)' > "$1/manifest.json"
}

# workflow_file <name> → the file to pass to `gh workflow run`: the checkout's
# .github/workflows/*.y*ml whose `name:` is <name>, else `gh workflow list`, else the name
workflow_file() {
  local name=$1 f n
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    n=$(sed -n -E "s/^name:[[:space:]]*['\"]?([^'\"]*[^'\"[:space:]])['\"]?[[:space:]]*$/\1/p" "$f" | head -1)
    if [ "$n" = "$name" ]; then basename "$f"; return 0; fi
  done
  n=$(gh workflow list -R "$REPO" --json name,path --jq ".[] | select(.name == \"$name\") | .path" 2>/dev/null | head -1)
  if [ -n "$n" ]; then basename "$n"; return 0; fi
  printf '%s\n' "$name"
}

# stub_lists <name>: warn when the stub's workflow_run.workflows does not carry the name
stub_lists() {
  local stub f
  stub=$(stub_file 2>/dev/null) || return 0
  f=".github/workflows/$stub"
  [ -f "$f" ] || return 0
  if ! yaml2json < "$f" 2>/dev/null | jq -e --arg n "$1" '((.on // .["true"] // {}) | .workflow_run.workflows // []) | index($n) != null' >/dev/null 2>&1; then
    printf '::warning::evidence workflow "%s" is not in %s workflow_run.workflows — its completion will never reach the dispatcher\n' "$1" "$stub"
  fi
}

read_state() { # <issue> <out>
  "$SWARM_LIB/state.sh" read "$1" > "$2"
}

consumer_for() { # <slot> → the first role of the stage whose evidence_before is the slot
  jq -r --arg s "$1" '[.stages[] | select((.evidence_before.workflow // "") == $s) | .roles[0].name] | first // empty' "$SWARM_ROOT/pipeline.json" 2>/dev/null
}

# ── fire ─────────────────────────────────────────────────────────────────────────

cmd_fire() {
  local issue=${1:-} slot=${2:-} head=${3:-} key=${4:-} consumer=${5:-}
  [ -n "$issue" ] && [ -n "$slot" ] && [ -n "$head" ] && [ -n "$key" ] || die "usage: evidence.sh fire <issue> <slot> <head> <key> [<consumer>] [--arg k v …]"
  shift 4
  [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && shift
  local -a extra=("$@")
  require_env REPO SWARM_STATE_KEY
  export ISSUE=$issue
  local name cap fires snap rc file default fired_at since err rid detail body cid existing snap2
  name=$(slot_name "$slot")
  cap=$(cfg '.limits.evidence_fires_per_issue' 2)
  [ -n "$consumer" ] || consumer=$(consumer_for "$slot")
  [ -n "$consumer" ] || die "evidence: no consumer role for slot $slot (pipeline.json evidence_before)"
  out evidence_workflow "$name"
  out evidence_key "$key"

  if [ -n "${SWARM_EVIDENCE_PERIMETER:-}" ]; then
    log "evidence: fire of $name refused — perimeter: $SWARM_EVIDENCE_PERIMETER"
    out evidence_fired false
    out evidence_reason "perimeter: $SWARM_EVIDENCE_PERIMETER"
    exit 9
  fi

  snap=$(tmpf .json) || die "evidence: no temp dir"
  read_state "$issue" "$snap" || { rc=$?; rm -f "$snap"; case $rc in 3) die "evidence: no state for #$issue" ;; 6) die "evidence: state #$issue has an invalid signature" ;; *) die "evidence: cannot read state #$issue" ;; esac; }
  fires=$(jq -r --arg s "$slot" '(.evidence.fires // {})[$s] // 0' "$snap")
  rm -f "$snap"

  skip() { # <reason>
    log "evidence: $name not fired — $1"
    synthetic_manifest "$EVIDENCE_DIR/$(evidence_dir "$name")" "$1" "$issue" "$head" "$key"
    out evidence_fired false
    out evidence_reason "$1"
    exit 0
  }
  if [ -n "${SWARM_MONTHLY_BRAKE:-}" ]; then
    skip "monthly budget: $SWARM_MONTHLY_BRAKE; evidence not run"
  fi
  if [ "$fires" -ge "$cap" ]; then
    skip "evidence fire cap reached ($fires); CI evidence only"
  fi

  # the claim counts the fire inside the CAS — a second writer cannot fire it too
  rc=0
  "$SWARM_LIB/state.sh" write "$issue" evidence-fired --arg workflow "$slot" --arg head "$head" --arg consumer "$consumer" \
    --arg cap "$cap" --arg key "$key" "${extra[@]}" >/dev/null || rc=$?
  case $rc in
    0) ;;
    5) log "evidence: fire of $name for $key already claimed (or the cap was reached) — nothing fired"; out evidence_fired false; out evidence_reason "already claimed"; exit 0 ;;
    *) die "evidence: cannot claim the fire of $name (state.sh exit $rc)" ;;
  esac

  file=$(workflow_file "$name")
  default=$(default_branch) || die "evidence: the default branch is unknown"
  stub_lists "$name"
  fired_at=$(now)
  since=$(jq -rn --arg t "$fired_at" '$t | fromdateiso8601 - 60 | todateiso8601')
  err=$(tmpf .err) || die "evidence: no temp dir"
  : > "$err"
  fire_once() {
    local try
    for try in 1 2 3; do
      if gh workflow run -R "$REPO" "$file" --ref "$default" -f issue="$issue" -f ref="$head" -f key="$key" >/dev/null 2>> "$err"; then return 0; fi
      log "evidence: gh workflow run $file failed (try $try): $(tail -n 1 "$err")"
      sleep $(( try * POLL ))
    done
    return 1
  }
  verify() {
    gh run list -R "$REPO" --workflow "$file" --event workflow_dispatch --json databaseId,displayTitle,createdAt --limit 20 \
      --jq "[.[] | select(.displayTitle | endswith(\" $key\")) | select(.createdAt >= \"$since\")] | sort_by(.createdAt) | .[0].databaseId // empty" 2>/dev/null
  }
  wait_for_run() {
    local i r=""
    for i in $(seq 1 $POLLS); do
      r=$(verify)
      if [ -n "$r" ]; then printf '%s\n' "$r"; return 0; fi
      [ "$i" -lt $POLLS ] && sleep "$POLL"
    done
    return 1
  }
  fire_once || log "evidence: three attempts of gh workflow run failed; looking for a run another writer may have created"
  rid=$(wait_for_run) || rid=""
  if [ -z "$rid" ]; then
    log "evidence: no run for $key within $((POLLS * POLL)) s; re-firing once"
    fire_once || log "evidence: the re-fire failed too"
    rid=$(wait_for_run) || rid=""
  fi
  if [ -n "$rid" ]; then
    "$SWARM_LIB/state.sh" write "$issue" evidence-run --arg key "$key" --arg run_id "$rid" >/dev/null \
      || log "evidence: evidence-run did not record run $rid (state.sh exit $?)"
    rm -f "$err"
    log "evidence: $name fired for $key as run $rid"
    out evidence_fired true
    out evidence_reason ""
    out evidence_run_id "$rid"
    printf '%s\n' "$rid"
    exit 0
  fi

  detail=$(tail -c 600 "$err" | redact | tr '\n' ' ')
  [ -n "$detail" ] || detail="no run of $name named with $key appeared within $((2 * POLLS * POLL)) s"
  "$SWARM_LIB/state.sh" write "$issue" block --arg reason fire --arg detail "$detail" >/dev/null \
    || log "evidence: could not record blocked:fire (state.sh exit $?)"
  body=$(tmpf .md) || die "evidence: no temp dir"
  "$SWARM_LIB/render.sh" fire-failed "$body" --sarg error "$detail" --arg key "$key" \
    --arg marker "$(marker died "issue=$issue" "key=$key")" || die "evidence: cannot render the fire-failed comment"
  if existing=$(find_comment "$issue" "$(marker_pred died "key=$key")"); then
    cid=$(printf '%s' "$existing" | jq -r .id)
    edit_comment "$cid" "$body" || log "evidence: could not edit comment $cid"
  else
    cid=$(post_comment "$issue" "$body") || log "evidence: could not post the fire-failed comment"
  fi
  [ -n "${cid:-}" ] && "$SWARM_LIB/state.sh" write "$issue" comment-id --arg target blocked --arg comment_id "$cid" >/dev/null 2>&1
  if [ -x "$SWARM_LIB/labels.sh" ]; then
    snap2=$(tmpf .json) || die "evidence: no temp dir"
    if "$SWARM_LIB/state.sh" read "$issue" > "$snap2" 2>/dev/null; then
      "$SWARM_LIB/labels.sh" project "$issue" "$snap2" || log "evidence: labels.sh project failed"
    fi
    rm -f "$snap2"
  fi
  "$SWARM_LIB/state.sh" sync-comment "$issue" >/dev/null 2>&1 || log "evidence: state comment not re-rendered"
  rm -f "$err" "$body"
  out evidence_fired false
  out evidence_reason "fire failed: $detail"
  die "evidence: no verified run of $name for $key after a re-fire — blocked:fire; /swarm resume re-fires it"
}

# ── wait ─────────────────────────────────────────────────────────────────────────

cmd_wait() {
  local slot=${1:-} head=${2:-} consumer=${3:-}
  [ -n "$slot" ] && [ -n "$head" ] && [ -n "$consumer" ] || die "usage: evidence.sh wait <slot> <head> <consumer>"
  require_env REPO ISSUE SWARM_STATE_KEY
  local name snap rc event seen run stage key status conclusion rid url
  name=$(slot_name "$slot")
  snap=$(tmpf .json) || die "evidence: no temp dir"
  read_state "$ISSUE" "$snap" || { rc=$?; rm -f "$snap"; case $rc in 3) die "evidence: no state for #$ISSUE" ;; 6) die "evidence: state #$ISSUE has an invalid signature" ;; *) die "evidence: cannot read state #$ISSUE" ;; esac; }
  if [ "$slot" = ci ]; then
    if jq -e '.pr != null' "$snap" >/dev/null; then event=pull_request; else event=push; fi
  else
    event=workflow_dispatch
  fi
  out evidence_event "$event"
  out evidence_workflow "$name"

  # (a) already seen
  seen=$(jq -c --arg h "$head" --arg n "$name" --arg e "$event" '(.evidence.seen[$h][$n][$e]) // empty' "$snap")
  if [ -n "$seen" ] && printf '%s' "$seen" | jq -e '.conclusion != null' >/dev/null; then
    log "evidence: $name on ${head:0:7} ($event) already seen: $(printf '%s' "$seen" | jq -r .conclusion)"
    out evidence_status complete
    out evidence_conclusion "$(printf '%s' "$seen" | jq -r .conclusion)"
    out evidence_run_id "$(printf '%s' "$seen" | jq -r .run_id)"
    out evidence_url "$(printf '%s' "$seen" | jq -r '.url // ""')"
    rm -f "$snap"
    exit 0
  fi

  # (b) ask GitHub
  run=$(gh api "repos/$REPO/actions/runs?head_sha=$head&event=$event&per_page=10" 2>/dev/null \
    | jq -c --arg n "$name" '[.workflow_runs[]? | select(.name == $n)] | sort_by(.created_at) | last // empty' 2>/dev/null) || run=""
  if [ -n "$run" ]; then
    status=$(printf '%s' "$run" | jq -r '.status // ""')
    rid=$(printf '%s' "$run" | jq -r '.id // 0')
    conclusion=$(printf '%s' "$run" | jq -r '.conclusion // ""')
    url=$(printf '%s' "$run" | jq -r '.html_url // ""')
    if [ "$status" = completed ] && [ -n "$conclusion" ]; then
      "$SWARM_LIB/state.sh" write "$ISSUE" evidence-seen --arg head "$head" --arg workflow "$name" --arg event "$event" \
        --arg run_id "$rid" --arg conclusion "$conclusion" --arg url "$url" \
        --arg at "$(printf '%s' "$run" | jq -r '.updated_at // empty')" >/dev/null || log "evidence: evidence-seen not recorded (state.sh exit $?)"
      log "evidence: $name on ${head:0:7} ($event) completed on GitHub: $conclusion (run $rid) — consumed"
      out evidence_status complete
      out evidence_conclusion "$conclusion"
      out evidence_run_id "$rid"
      out evidence_url "$url"
      rm -f "$snap"
      exit 0
    fi
    log "evidence: $name on ${head:0:7} is $status on GitHub (run $rid) — waiting"
  else
    rid=0
    url=""
    log "evidence: no $name run for ${head:0:7} ($event) known to GitHub yet — waiting for workflow_run"
  fi

  stage=$(jq -r .stage "$snap")
  if jq -e --arg s "$slot" --arg h "$head" '.status == "evidence" and .evidence.pending != null and .evidence.pending.workflow == $s and .evidence.pending.head == $h' "$snap" >/dev/null; then
    key=$(jq -r '.evidence.pending.key' "$snap")
    if [ "$rid" != 0 ]; then
      "$SWARM_LIB/state.sh" write "$ISSUE" evidence-run --arg key "$key" --arg run_id "$rid" >/dev/null || log "evidence: evidence-run not recorded (state.sh exit $?)"
    fi
  else
    key=$("$SWARM_LIB/state.sh" next-key "$snap" "$stage" evidence)
    "$SWARM_LIB/state.sh" write "$ISSUE" evidence-pending --arg workflow "$slot" --arg head "$head" --arg consumer "$consumer" \
      --arg run_id "$rid" --arg key "$key" >/dev/null || { rc=$?; rm -f "$snap"; die "evidence: cannot record the pending wait (state.sh exit $rc)"; }
  fi
  rm -f "$snap"
  out evidence_status pending
  out evidence_conclusion ""
  out evidence_run_id "$rid"
  out evidence_url "$url"
  out evidence_key "$key"
  exit 0
}

# ── collect ──────────────────────────────────────────────────────────────────────

cmd_collect() {
  local issue=${1:-} head=${2:-} dir=${3:-$EVIDENCE_DIR}
  [ -n "$issue" ] && [ -n "$head" ] || die "usage: evidence.sh collect <issue> <head> [<dir>]"
  require_env REPO SWARM_STATE_KEY
  local snap rc ev_event plan e wf d rid concl url st index="{}" existing
  snap=$(tmpf .json) || die "evidence: no temp dir"
  read_state "$issue" "$snap" || { rc=$?; rm -f "$snap"; case $rc in 3) die "evidence: no state for #$issue" ;; 6) die "evidence: state #$issue has an invalid signature" ;; *) die "evidence: cannot read state #$issue" ;; esac; }
  mkdir -p "$dir"
  ev_event=push
  jq -e '.pr != null' "$snap" >/dev/null && ev_event=pull_request
  plan=$(tmpf .plan) || die "evidence: no temp dir"
  jq -c --arg h "$head" --arg ev "$ev_event" '
    (.evidence.seen[$h] // {}) | to_entries[]
    | .key as $wf
    | (.value[$ev] // .value.workflow_dispatch // (.value | to_entries | sort_by(.value.at) | last | .value) // null) as $r
    | select($r != null)
    | {workflow: $wf, run_id: ($r.run_id // 0), conclusion: ($r.conclusion // null), url: ($r.url // null), head: $h}' "$snap" > "$plan"
  # synthetic manifests written by a skipped fire are kept and indexed
  for existing in "$dir"/*/manifest.json; do
    [ -f "$existing" ] || continue
    if jq -e '.synthetic == true' "$existing" >/dev/null 2>&1; then
      d=$(basename "$(dirname "$existing")")
      index=$(printf '%s' "$index" | jq -c --arg d "$d" --arg h "$head" --arg r "$(jq -r '.sections.all.reason // ""' "$existing")" \
        '.[$d] = {workflow: $d, run_id: null, conclusion: null, head: $h, url: null, artifact: "skipped", reason: $r}')
    fi
  done
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    wf=$(printf '%s' "$e" | jq -r .workflow)
    d=$(evidence_dir "$wf")
    rid=$(printf '%s' "$e" | jq -r '.run_id // 0')
    concl=$(printf '%s' "$e" | jq -r '.conclusion // empty')
    url=$(printf '%s' "$e" | jq -r '.url // empty')
    mkdir -p "$dir/$d"
    st=ok
    if [ "$rid" = 0 ] || [ -z "$rid" ]; then
      st=missing
    elif ! gh run download -R "$REPO" "$rid" -D "$dir/$d" >/dev/null 2>&1; then
      st=missing
    else
      evidence_hoist "$dir/$d"
    fi
    if [ "$st" = missing ] || [ ! -f "$dir/$d/manifest.json" ]; then
      if [ "$st" = ok ]; then synthetic_manifest "$dir/$d" "manifest missing" "$issue" "$head"; else synthetic_manifest "$dir/$d" "artifact missing" "$issue" "$head"; fi
      st=missing
    fi
    if [ "$rid" != 0 ] && [ -n "$concl" ] && [ "$concl" != success ]; then
      gh run view -R "$REPO" "$rid" --log-failed 2>/dev/null | tail -n 120 > "$dir/$d/failed.log"
      [ -s "$dir/$d/failed.log" ] || rm -f "$dir/$d/failed.log"
    fi
    index=$(printf '%s' "$index" | jq -c --arg d "$d" --arg st "$st" --argjson e "$e" \
      '.[$d] = {workflow: $e.workflow, run_id: $e.run_id, conclusion: $e.conclusion, head: $e.head, url: $e.url, artifact: $st}')
  done < "$plan"
  printf '%s' "$index" | jq . > "$dir/index.json"
  rm -f "$plan" "$snap"
  out evidence "$(printf '%s' "$index" | jq -r 'to_entries | map("\(.key)=\(.value.artifact)") | join(",")')"
  log "evidence: collected for ${head:0:7}: $(printf '%s' "$index" | jq -r 'to_entries | map("\(.key)=\(.value.artifact)") | join(", ") | if . == "" then "nothing recorded" else . end')"
  exit 0
}

case ${1:-} in
  fire) shift; cmd_fire "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  *) sed -n '2,48p' "$0" >&2; exit 1 ;;
esac
