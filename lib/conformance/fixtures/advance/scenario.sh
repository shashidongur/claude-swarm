#!/usr/bin/env bash
# scenario.sh — runs advance.sh (or reconcile.sh / advance-failed.sh / route.sh) the
# way the advance job does: a project checkout with an origin, the integration
# branch, the handoff under .swarm-run/, the state document in the shim's store and
# the working comment in the shim's thread; prints PROBE lines the cases assert.
# Knobs (env; every one optional):
#
#   KEY               the dispatch key (default 7:build:dev:app:1); ISSUE (7)
#   SC_STATUS         state status (running); SC_PATH full|short; SC_PR (9; "none")
#   SC_LANES          JSON list (["api","app"])
#   SC_STATE_PATCH    jq filter applied to the built state (after the placeholders)
#   SC_HANDOFF        fixtures/advance/handoffs/<name>/ copied into .swarm-run/ ("none")
#   SC_RESULT_PATCH   jq filter applied to .swarm-run/result.json
#   SC_EXEC           fixtures/exec/<name>.json gzipped to .swarm-run/audit/execution.json.gz
#                     (healthy; "none")
#   SC_CRITIC         fixtures/advance/critic/<name>/ copied into .swarm-run/critic/
#   SC_MAIN_FILES     "path=content" lines committed on main (\n decoded)
#   SC_BASE_FILES     "path=content" lines committed on the branch BEFORE the attempt
#                     (the attempt's base is the branch head after them)
#   SC_BRANCH_FILES   "path=content" lines committed on the branch AS the attempt's push
#                     (with the trailer unless SC_TRAILER=0)
#   SC_NO_BRANCH=1    no integration branch on origin (triage)
#   SC_REWRITE=1      the attempt's push rewrites history (base no longer an ancestor)
#   SC_SNAPSHOT=1     write .swarm-claim/refs-snapshot.txt at claim time
#   SC_EXTRA_REF      a ref pushed after the snapshot (activity fallback), e.g. refs/heads/main2
#   SC_SCRIPT         advance|reconcile|advance-failed|route (advance)
#   SC_NO_COMMENT=1   no working comment in the thread
#   SC_MEMORY=1       a scratch swarm checkout under .swarm with a pushable origin (retro)
#   SC_MEMORY_NO_PUSH=1  the scratch origin refuses pushes
#   SC_CONFIG_PATCH   jq filter applied to the config copy (.swarm-run/config.json)
#   SC_PROBE          extra shell run after the script (PROBE lines)
# Placeholders @BASE and @HEAD are replaced in the state, result.json and every shim
# fixture under cmd/ and GET/.
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

G=(git -c user.name=swarm-harness -c user.email=harness@example.invalid)
conf="$SWARM_ROOT/lib/conformance"
FX="$conf/fixtures/advance"
issue=${ISSUE:-7}
key=${KEY:-7:build:dev:app:1}
branch=claude/issue-7-live-session-capacity
now=${SWARM_NOW:-2026-09-06T15:00:00Z}
export ISSUE=$issue KEY=$key

write_files() {
  local line p c
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    p=${line%%=*}
    c=${line#*=}
    mkdir -p "$(dirname "$p")"
    printf '%b' "$c" > "$p"
    git add -- "$p"
  done <<< "$1"
}

# ── the project: main, origin, the branch, the attempt ──────────────────────────

if [ -n "${SC_MAIN_FILES:-}" ]; then
  write_files "$SC_MAIN_FILES"
  "${G[@]}" commit -q -m "main files"
fi
git init -q --bare "$RUNNER_TEMP/origin.git"
git remote add origin "$RUNNER_TEMP/origin.git"
git push -q origin main 2>/dev/null || die "scenario: cannot push main"
BASE=$(git rev-parse HEAD)
HEAD=$BASE
if [ "${SC_NO_BRANCH:-0}" != 1 ]; then
  git checkout -q -b "$branch"
  if [ -n "${SC_BASE_FILES:-}" ]; then
    write_files "$SC_BASE_FILES"
    "${G[@]}" commit -q -m "base files" --trailer "Swarm-Issue: #$issue"
  fi
  BASE=$(git rev-parse HEAD)
  git push -q origin "$branch" 2>/dev/null
  if [ "${SC_SNAPSHOT:-0}" = 1 ]; then
    # .swarm-claim, not .swarm-run: in production resolve takes this snapshot into the
    # swarm-tree artifact at claim time and advance downloads it there. .swarm-run is
    # the handoff the ROLE uploads, and a perimeter check must not read its evidence
    # from the party it is checking.
    mkdir -p .swarm-claim
    git ls-remote origin 2>/dev/null | LC_ALL=C sort > .swarm-claim/refs-snapshot.txt
  fi
  if [ -n "${SC_BRANCH_FILES:-}" ]; then
    write_files "$SC_BRANCH_FILES"
    if [ "${SC_TRAILER:-1}" = 1 ]; then "${G[@]}" commit -q -m "attempt push" --trailer "Swarm-Issue: #$issue"; else "${G[@]}" commit -q -m "attempt push"; fi
    if [ "${SC_REWRITE:-0}" = 1 ]; then
      git reset -q --soft "$(git rev-parse HEAD~2 2>/dev/null || git rev-parse HEAD~1)"
      "${G[@]}" commit -q -m "rewritten" --trailer "Swarm-Issue: #$issue"
      git push -q -f origin "$branch" 2>/dev/null
    else
      git push -q origin "$branch" 2>/dev/null
    fi
  fi
  HEAD=$(git rev-parse HEAD)
  if [ -n "${SC_EXTRA_REF:-}" ]; then git push -q origin "HEAD:$SC_EXTRA_REF" 2>/dev/null; fi
  git checkout -q main
  git fetch -q origin 2>/dev/null
fi
git checkout -q main 2>/dev/null || true

# ── the handoff ─────────────────────────────────────────────────────────────────

mkdir -p .swarm-run/artifacts .swarm-run/audit .swarm-run/advance
if [ "${SC_HANDOFF:-none}" != none ]; then
  [ -d "$FX/handoffs/$SC_HANDOFF" ] || die "scenario: no handoff fixture $SC_HANDOFF"
  cp -r "$FX/handoffs/$SC_HANDOFF/." .swarm-run/
fi
if [ -f .swarm-run/result.json ]; then
  sed -i "s/@HEAD/$HEAD/g; s/@BASE/$BASE/g" .swarm-run/result.json
  if [ -n "${SC_RESULT_PATCH:-}" ]; then
    jq "$SC_RESULT_PATCH" .swarm-run/result.json > .swarm-run/result.tmp && mv .swarm-run/result.tmp .swarm-run/result.json
  fi
fi
case ${SC_EXEC:-healthy} in
  none) ;;
  */*) [ -f "$conf/fixtures/$SC_EXEC.json" ] || die "scenario: no exec fixture $SC_EXEC"
     gzip -c "$conf/fixtures/$SC_EXEC.json" > .swarm-run/audit/execution.json.gz ;;
  *) [ -f "$conf/fixtures/exec/${SC_EXEC:-healthy}.json" ] || die "scenario: no exec fixture ${SC_EXEC:-healthy}"
     gzip -c "$conf/fixtures/exec/${SC_EXEC:-healthy}.json" > .swarm-run/audit/execution.json.gz ;;
esac
if [ -n "${SC_CRITIC:-}" ]; then
  [ -d "$FX/critic/$SC_CRITIC" ] || die "scenario: no critic fixture $SC_CRITIC"
  mkdir -p .swarm-run/critic
  cp -r "$FX/critic/$SC_CRITIC/." .swarm-run/critic/
  [ -f .swarm-run/critic/critic.json ] && sed -i "s/@KEY/$key/g" .swarm-run/critic/critic.json
fi
cp "$conf/fixtures/config/user-owned.json" .swarm-run/config.json
if [ -n "${SC_CONFIG_PATCH:-}" ]; then
  jq "$SC_CONFIG_PATCH" .swarm-run/config.json > .swarm-run/config.tmp && mv .swarm-run/config.tmp .swarm-run/config.json || die "scenario: SC_CONFIG_PATCH failed"
fi
export CONFIG_JSON="$PWD/.swarm-run/config.json"

# ── the state and the thread in the shim ────────────────────────────────────────

pr=${SC_PR:-9}
[ "$pr" = none ] && pr=""
state=$(tmpf .json)
jq -n --arg key "$key" --arg status "${SC_STATUS:-running}" --arg path "${SC_PATH:-full}" --arg pr "$pr" \
  --arg lanes "${SC_LANES:-[\"api\",\"app\"]}" --arg now "$now" --arg run_id "${RUN_ID:-424242}" --arg comment_id 101 \
  --slurpfile pipeline "$SWARM_ROOT/pipeline.json" -f "$FX/state-builder.jq" > "$state" || die "scenario: state builder failed"
sed -i "s/@HEAD/$HEAD/g; s/@BASE/$BASE/g" "$state"
if [ -n "${SC_STATE_PATCH:-}" ]; then
  jq "$SC_STATE_PATCH" "$state" > "$state.tmp" && mv "$state.tmp" "$state" || die "scenario: SC_STATE_PATCH failed"
fi
mkdir -p "$SWARM_FAKE_GH/state" "$SWARM_FAKE_GH/GET"
SWARM_STATE_KEY=$SWARM_STATE_KEY "$SWARM_LIB/state.sh" sign < "$state" > "$SWARM_FAKE_GH/state/issues-$issue.json" || die "scenario: cannot sign the state"
cp "$state" .swarm-run/state.json
for f in "$SWARM_FAKE_GH"/cmd/*.json "$SWARM_FAKE_GH"/GET/*.json; do
  [ -f "$f" ] && sed -i "s/@HEAD/$HEAD/g; s/@BASE/$BASE/g" "$f"
done
cfile="$SWARM_FAKE_GH/GET/repos%2Fo%2Fr%2Fissues%2F$issue%2Fcomments.json"
[ -f "$cfile" ] || printf '[]' > "$cfile"
if [ "${SC_NO_COMMENT:-0}" != 1 ]; then
  role=$(jq -r '.current.role' "$state")
  attempt=$(jq -r '.current.attempt' "$state")
  stage=$(jq -r '.stage' "$state")
  wc=$(jq -cn --arg b "🔨 **$role** · ⏳ running · attempt $attempt · started $now · https://github.com/o/r/actions/runs/424242
<!-- swarm: v2 | kind=stage | issue=$issue | stage=$stage | role=$role | attempt=$attempt | key=$key | run=424242 | status=running | at=$now -->" \
    '{id: 101, body: $b, user: {login: "github-actions[bot]", type: "Bot"}, created_at: "2026-09-06T14:41:39Z", html_url: "https://github.com/o/r/issues/7#issuecomment-101"}')
  jq --argjson c "$wc" '. + [$c]' "$cfile" > "$cfile.tmp" && mv "$cfile.tmp" "$cfile"
fi
printf '1000' > "$SWARM_FAKE_GH/.next-comment-id"

# ── a scratch swarm checkout for retro ──────────────────────────────────────────

if [ "${SC_MEMORY:-0}" = 1 ]; then
  mkdir -p .swarm/memory/github.com/o/r/gotchas/auto .swarm/memory/github.com/o/r/adrs .swarm/memory/github.com/o/r/postmortems .swarm/memory/github.com/o/r/runs
  printf '# memory\n\n- [gotchas](gotchas/INDEX.md)\n' > .swarm/memory/github.com/o/r/MEMORY.md
  printf -- '---\nname: existing-gotcha\ndescription: an existing curated gotcha\nmetadata: { type: gotcha }\n---\n# existing\n' > .swarm/memory/github.com/o/r/gotchas/existing-gotcha.md
  ( cd .swarm && git init -q -b v2 . && "${G[@]}" add -A && "${G[@]}" commit -q -m "memory seed" ) || die "scenario: cannot seed .swarm"
  git init -q --bare "$RUNNER_TEMP/swarm-origin.git"
  if [ "${SC_MEMORY_NO_PUSH:-0}" = 1 ]; then
    git -C .swarm remote add origin "$RUNNER_TEMP/does-not-exist.git"
  else
    git -C .swarm remote add origin "$RUNNER_TEMP/swarm-origin.git"
    git -C .swarm push -q origin v2 2>/dev/null
  fi
  printf '.swarm/\n' >> .git/info/exclude
  export SWARM_REPO=o/claude-swarm SWARM_REF=v2 MEMORY_CHECKOUT=.swarm
fi

# ── run ─────────────────────────────────────────────────────────────────────────

export WORKFLOW_REF="o/r/.github/workflows/swarm-dispatch.yml@refs/heads/main" OWNER=owner
export SWARM_NOW=$now RUN_DIR=.swarm-run
case ${SC_SCRIPT:-advance} in
  advance) "$SWARM_LIB/advance.sh"; rc=$? ;;
  reconcile) "$SWARM_LIB/reconcile.sh"; rc=$? ;;
  advance-failed) "$SWARM_LIB/advance-failed.sh"; rc=$? ;;
  route) "$SWARM_LIB/route.sh" "$issue" "$key" "${RUN_ID:-424242}"; rc=$? ;;
  *) die "scenario: unknown SC_SCRIPT ${SC_SCRIPT}" ;;
esac
printf 'PROBE: %s exit %s\n' "${SC_SCRIPT:-advance}" "$rc"
printf 'PROBE: base %s head %s\n' "$BASE" "$HEAD"
if [ -n "${SC_PROBE:-}" ]; then
  BASE=$BASE HEAD=$HEAD bash -c "$SC_PROBE" || true
fi
exit "$rc"
