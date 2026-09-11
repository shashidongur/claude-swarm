#!/usr/bin/env bash
# memory-pr.sh — retro's memory entries become a pull request on the swarm repository
# (spec §12.3, D9). Run by advance at retro — the only job with SWARM_TOKEN and no
# model step.
#
#   memory-pr.sh <issue> <result.json> <state.json>
#
#   1. V13 re-applied: every memory[] entry's path matches the grammar and one of
#      postmortems/<N>.md, adrs/<NNNN>-<slug>.md, gotchas/auto/<slug>.md, runs/<N>.json;
#      never an existing file except the issue's own postmortem/runs; never a
#      symlink; content_file resolves under $RUN_DIR/artifacts/. A bad entry is
#      skipped and named in the comment; the rest still land.
#   2. Applied into the swarm checkout at $MEMORY_CHECKOUT (default .swarm — the
#      credentialed checkout of the advance job) under <memory.path> (config; default
#      memory/github.com/<owner>/<repo>): the entries, runs/<N>.json from the state
#      (dispatches + totals), the regenerated INDEX files (memory-index.sh); MEMORY.md
#      must stay ≤ 40 lines.
#   3. Commit `memory(<owner>/<repo>): #<N> retro` + `Swarm-Issue: #<N>`; push -f to
#      memory/<owner>-<repo>/<N> (the branch is ours; a re-run replaces it); then
#      an open PR for that head (Pulls API) → `gh pr edit`, else `gh pr create` — under SWARM_TOKEN.
#   4. On any failure after the commit: `git format-patch` into
#      $RUN_DIR/advance/memory-patch/ (uploaded by the workflow as
#      swarm-<N>-memory-patch) and the reason on stdout.
#
# Outputs (GITHUB_OUTPUT and stdout as `memory_pr=<n>` / `memory_artifact=<name>` /
# `memory_reason=<text>` / `memory_files=<list>`): exit 0 when the PR exists or was
# updated, 2 when the patch fallback was used, 1 only on a usage error.
#
# Environment: REPO (the project), SWARM_REPO (owner/repo of the swarm; default from
# `git -C $MEMORY_CHECKOUT remote get-url origin`), SWARM_REF (base branch; default
# v2), SWARM_TOKEN (the PAT; without it the PR step is skipped → patch fallback),
# CONFIG_JSON (memory.path), RUN_DIR, MEMORY_CHECKOUT, GH_TOKEN.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${1:-}
RESULT=${2:-}
STATE=${3:-}
[ -n "$ISSUE" ] && [ -n "$RESULT" ] && [ -n "$STATE" ] || die "usage: memory-pr.sh <issue> <result.json> <state.json>"
require_env REPO
[ -f "$RESULT" ] || die "memory-pr: no such file: $RESULT"
[ -f "$STATE" ] || die "memory-pr: no such file: $STATE"
RUN_DIR=${RUN_DIR:-.swarm-run}
CHECKOUT=${MEMORY_CHECKOUT:-.swarm}
SWARM_REF=${SWARM_REF:-v2}
G=(git -c user.name=swarm-dispatch -c user.email=swarm@users.noreply.github.com)

finish() { # <exit> <key=value>…
  local rc=$1 kv
  shift
  for kv in "$@"; do
    out "${kv%%=*}" "${kv#*=}"
    printf '%s\n' "$kv"
  done
  exit "$rc"
}

[ -d "$CHECKOUT/.git" ] || [ -f "$CHECKOUT/.git" ] || finish 2 "memory_reason=no swarm checkout at $CHECKOUT" "memory_artifact="
if [ -z "${SWARM_REPO:-}" ]; then
  SWARM_REPO=$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')
fi

mem_rel=""
[ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ] && mem_rel=$(jq -r '.memory.path // empty' "$CONFIG_JSON" 2>/dev/null)
[ -n "$mem_rel" ] || mem_rel="memory/github.com/$REPO"
case $mem_rel in /*|*..*) finish 2 "memory_reason=memory path refused: $mem_rel" "memory_artifact=" ;; esac
MEM="$CHECKOUT/$mem_rel"
mkdir -p "$MEM"

owner_repo_dash=$(printf '%s' "$REPO" | tr '/' '-')
BRANCH="memory/$owner_repo_dash/$ISSUE"
title=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.title // ""' 2>/dev/null | sanitize | tr -d '\r\n' | cut -c1-80)
[ -n "$title" ] || title="issue #$ISSUE"

# ── 1. entries (V13 re-applied) ─────────────────────────────────────────────────

grammar='^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$'
applied=()
skipped=()
n=$(jq '(.memory // []) | length' "$RESULT")
i=0
while [ "$i" -lt "$n" ]; do
  p=$(jq -r ".memory[$i].path // empty" "$RESULT")
  cf=$(jq -r ".memory[$i].content_file // empty" "$RESULT")
  kind=$(jq -r ".memory[$i].kind // empty" "$RESULT")
  i=$((i + 1))
  reason=""
  if ! [[ $p =~ $grammar ]]; then reason="path grammar"
  elif ! { [ "$p" = "postmortems/$ISSUE.md" ] || [ "$p" = "runs/$ISSUE.json" ] \
           || [[ $p =~ ^adrs/[0-9]{4}-[a-z0-9][a-z0-9-]*\.md$ ]] || [[ $p =~ ^gotchas/auto/[a-z0-9][a-z0-9-]*\.md$ ]]; }; then reason="not an allowed memory path"
  elif [ -L "$MEM/$p" ]; then reason="target is a symlink"
  elif [ -e "$MEM/$p" ] && [ "$p" != "postmortems/$ISSUE.md" ] && [ "$p" != "runs/$ISSUE.json" ]; then reason="target exists (a proposal never overwrites)"
  fi
  cf=${cf#.swarm-run/}
  cf=${cf#artifacts/}
  src="$RUN_DIR/artifacts/$cf"
  if [ -z "$reason" ]; then
    if [ -z "$cf" ] || [ ! -f "$src" ] || [ -L "$src" ]; then reason="content_file missing"
    else
      rabs=$(realpath -e -- "$RUN_DIR/artifacts" 2>/dev/null) || rabs=""
      abs=$(realpath -e -- "$src" 2>/dev/null) || abs=""
      case $abs in "$rabs"/*) ;; *) reason="content_file outside artifacts" ;; esac
    fi
  fi
  if [ -z "$reason" ]; then
    if grep -qF -- '<!--' "$src"; then reason="content contains <!--"; fi
    if grep -qE -- '@[A-Za-z0-9-]+' "$src"; then reason="content contains an @handle"; fi
  fi
  if [ -n "$reason" ]; then
    log "memory-pr: skipped $p ($reason)"
    skipped+=("$p ($reason)")
    continue
  fi
  mkdir -p "$MEM/$(dirname "$p")"
  if [ "$kind" = runs ] || [ "${p##*.}" = json ]; then jq . "$src" > "$MEM/$p" 2>/dev/null || cp "$src" "$MEM/$p"; else cp "$src" "$MEM/$p"; fi
  applied+=("$p")
done

# runs/<N>.json from the state (never from the role)
mkdir -p "$MEM/runs"
jq '{v: 2, issue, repo, path, pipeline_sha, swarm_sha, merged_at, merged_pr, merge_sha, branch, pr,
     dispatches: (.dispatches // []), totals: (.totals // {}), rework: (.rework // {}), evidence_fires: (.evidence.fires // {}),
     models: (.models // {}), stages: (.stages // {})}' "$STATE" > "$MEM/runs/$ISSUE.json" 2>/dev/null || cp "$STATE" "$MEM/runs/$ISSUE.json"
applied+=("runs/$ISSUE.json")

"$SWARM_LIB/memory-index.sh" "$MEM" >/dev/null 2>&1 || log "memory-pr: index regeneration reported a problem"

if [ -f "$MEM/MEMORY.md" ] && [ "$(wc -l < "$MEM/MEMORY.md")" -gt 40 ]; then
  log "memory-pr: MEMORY.md is $(wc -l < "$MEM/MEMORY.md") lines (> 40) — the PR body says so"
  skipped+=("MEMORY.md exceeds 40 lines")
fi

files_list=$(printf -- '- %s\n' "${applied[@]}")
skipped_note=""
[ ${#skipped[@]} -gt 0 ] && skipped_note=$(printf '\nSkipped: %s' "$(printf '%s; ' "${skipped[@]}" | sed 's/; $//')")

# ── 2. commit ───────────────────────────────────────────────────────────────────

if ! "${G[@]}" -C "$CHECKOUT" add -A -- "$mem_rel" 2>/dev/null; then
  finish 2 "memory_reason=git add failed in $CHECKOUT" "memory_artifact=" "memory_files=${applied[*]}"
fi
if "${G[@]}" -C "$CHECKOUT" diff --cached --quiet -- "$mem_rel" 2>/dev/null; then
  log "memory-pr: nothing changed under $mem_rel"
fi
"${G[@]}" -C "$CHECKOUT" commit -q --allow-empty -m "memory($REPO): #$ISSUE retro" --trailer "Swarm-Issue: #$ISSUE" 2>/dev/null \
  || finish 2 "memory_reason=git commit failed in $CHECKOUT" "memory_artifact=" "memory_files=${applied[*]}"

patch_fallback() { # <reason>
  local dir="$RUN_DIR/advance/memory-patch" name="swarm-$ISSUE-memory-patch"
  mkdir -p "$dir"
  "${G[@]}" -C "$CHECKOUT" format-patch -1 -o "$(realpath -m "$dir")" HEAD >/dev/null 2>&1 || log "memory-pr: format-patch failed"
  log "memory-pr: memory not written ($1); patch in $dir"
  finish 2 "memory_reason=$1" "memory_artifact=$name" "memory_files=${applied[*]}" "memory_pr="
}

# ── 3. push + PR ────────────────────────────────────────────────────────────────

[ -n "${SWARM_TOKEN:-}" ] || patch_fallback "SWARM_TOKEN is not set"
[ -n "$SWARM_REPO" ] || patch_fallback "the swarm repository is unknown (SWARM_REPO)"
err=$(tmpf .err) || die "memory-pr: no temp dir"
if ! "${G[@]}" -C "$CHECKOUT" push -f origin "HEAD:refs/heads/$BRANCH" >/dev/null 2> "$err"; then
  patch_fallback "push refused: $(tail -n 1 "$err" | redact | head -c 200)"
fi

body=$(tmpf .md) || die "memory-pr: no temp dir"
"$SWARM_LIB/render.sh" memory-pr "$body" --arg repo "$REPO" --arg issue "$ISSUE" --sarg title "$title" \
  --arg pr "$(jq -r '.merged_pr // .pr // "?"' "$STATE")" --arg merged_at "$(jq -r '.merged_at // "?"' "$STATE")" \
  --arg files "$files_list$skipped_note" || die "memory-pr: cannot render the PR body"

existing=$(GH_TOKEN="$SWARM_TOKEN" gh api "repos/$SWARM_REPO/pulls?state=open&head=${SWARM_REPO%%/*}:$BRANCH" --jq '.[0].number // empty' 2>/dev/null) || existing=""
if [ -n "$existing" ]; then
  if GH_TOKEN="$SWARM_TOKEN" gh pr edit --repo "$SWARM_REPO" "$existing" --title "memory($REPO): #$ISSUE $title" --body-file "$body" >/dev/null 2> "$err"; then
    rm -f "$body" "$err"
    log "memory-pr: PR #$existing updated on $SWARM_REPO"
    finish 0 "memory_pr=$existing" "memory_artifact=" "memory_reason=" "memory_files=${applied[*]}"
  fi
  patch_fallback "gh pr edit failed: $(tail -n 1 "$err" | redact | head -c 200)"
fi
created=$(GH_TOKEN="$SWARM_TOKEN" gh pr create --repo "$SWARM_REPO" --base "$SWARM_REF" --head "$BRANCH" \
  --title "memory($REPO): #$ISSUE $title" --body-file "$body" 2> "$err") || {
  patch_fallback "gh pr create failed: $(tail -n 1 "$err" | redact | head -c 200)"
}
rm -f "$body" "$err"
num=$(printf '%s' "$created" | jq -r '.number // empty' 2>/dev/null)
[ -n "$num" ] || num=$(printf '%s' "$created" | grep -oE '/pull/[0-9]+' | tail -1 | grep -oE '[0-9]+$')
[ -n "$num" ] || num=$(GH_TOKEN="$SWARM_TOKEN" gh api "repos/$SWARM_REPO/pulls?state=open&head=${SWARM_REPO%%/*}:$BRANCH" --jq '.[0].number // empty' 2>/dev/null)
[ -n "$num" ] || patch_fallback "the pull request was created but its number could not be read"
log "memory-pr: PR #$num opened on $SWARM_REPO"
finish 0 "memory_pr=$num" "memory_artifact=" "memory_reason=" "memory_files=${applied[*]}"
