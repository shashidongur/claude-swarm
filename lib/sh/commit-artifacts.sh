#!/usr/bin/env bash
# commit-artifacts.sh — a finished role's artifacts reach the project (spec §9.1).
#
#   commit-artifacts.sh <issue> <state.json> [--rubric <name>]
#
# Two modes, chosen by the signed state:
#
#   state.pr == null (triage → architecture, planner): the dispatcher may push. The
#     files under $ARTIFACTS_SRC (default .swarm-run/artifacts) are copied BY BASENAME
#     into <artifacts_dir>/<N>/ on the integration branch — created from
#     origin/<default_branch> when it does not exist yet (after triage) — together with
#     critic/<rubric>-a<attempt>.json (the accepted critic score, when given),
#     runs.json (the state's dispatch records + totals) and a README.md written once.
#     Committed as `docs(swarm): #<N> <stage> artifacts` with the trailer
#     `Swarm-Issue: #<N>` (as swarm-dispatch) and pushed to HEAD:refs/heads/<branch>
#     only — any other ref is refused here. No diff → no commit, no push.
#
#   state.pr != null: the dispatcher never pushes to a branch with a pull request.
#     Every file is staged on the state branch (`state.sh stage-pending`, recorded
#     with its sha256 in the signed state) unless the pushed head already carries it
#     with the same content — landing is content-keyed.
#
# Outputs (GITHUB_OUTPUT + stdout): mode=commit|stage, branch=<name>, landed=<files>,
# staged=<files>, docs_head=<sha of the docs commit, commit mode>. Exit 0; a push or
# staging failure exits 1 with the reason (advance reports it in the stage comment).
#
# Environment: REPO, SWARM_STATE_KEY (staging), CONFIG_JSON (artifacts_dir,
# default_branch, branch_prefix), ARTIFACTS_SRC, CRITIC_JSON (the accepted critic file),
# HEAD (the pushed head of a write role, for the content check), STAGE_NOTHING=1 (the
# role is the last write role: nothing is staged after it), GH_TOKEN.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

ISSUE=${1:-}
STATE=${2:-}
[ -n "$ISSUE" ] && [ -n "$STATE" ] || die "usage: commit-artifacts.sh <issue> <state.json> [--rubric <name>]"
shift 2
RUBRIC=""
while [ $# -gt 0 ]; do
  case $1 in
    --rubric) RUBRIC=$2; shift 2 ;;
    *) die "commit-artifacts: unknown option $1" ;;
  esac
done
require_env REPO
[ -f "$STATE" ] || die "commit-artifacts: no such file: $STATE"
SRC=${ARTIFACTS_SRC:-.swarm-run/artifacts}
G=(git -c user.name=swarm-dispatch -c user.email=swarm@users.noreply.github.com)

C() { [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ] && jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null; }
S() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }

ARTIFACTS_DIR=$(C '.artifacts_dir'); ARTIFACTS_DIR=${ARTIFACTS_DIR:-docs/swarm}
DEFAULT=$(C '.default_branch'); DEFAULT=${DEFAULT:-main}
PREFIX=$(C '.branch_prefix'); PREFIX=${PREFIX:-claude/issue-}
STAGE=$(S '.stage')
ATTEMPT=$(S '.current.attempt'); ATTEMPT=${ATTEMPT:-1}
PR=$(S '.pr')
BRANCH=$(S '.branch')
DEST="$ARTIFACTS_DIR/$ISSUE"

safe_name() { # a basename the copy rule accepts
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# the files to land: <src path>\t<name under DEST>
plan=$(tmpf .plan) || die "commit-artifacts: no temp dir"
: > "$plan"
if [ -d "$SRC" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -L "$f" ] && { log "commit-artifacts: $f is a symlink — skipped"; continue; }
    [ -s "$f" ] || { log "commit-artifacts: $f is empty — skipped"; continue; }
    b=$(basename "$f")
    safe_name "$b" || { log "commit-artifacts: $b refused by the name rule — skipped"; continue; }
    printf '%s\t%s\n' "$f" "$b" >> "$plan"
  done < <(find "$SRC" -type f 2>/dev/null | LC_ALL=C sort)
fi
if [ -n "$RUBRIC" ] && [ -n "${CRITIC_JSON:-}" ] && [ -f "$CRITIC_JSON" ] && safe_name "$RUBRIC"; then
  printf '%s\t%s\n' "$CRITIC_JSON" "critic/$RUBRIC-a$ATTEMPT.json" >> "$plan"
fi
runs=$(tmpf .runs) || die "commit-artifacts: no temp dir"
jq '{v: 2, issue, dispatches: (.dispatches // []), totals: (.totals // {}), rework: (.rework // {}), updated_at: (.log // [] | last | .at // null)}' "$STATE" > "$runs" \
  || die "commit-artifacts: cannot build runs.json from the state"
printf '%s\t%s\n' "$runs" "runs.json" >> "$plan"

landed=()
staged=()

# ── commit mode ─────────────────────────────────────────────────────────────────

if [ -z "$PR" ] || [ "$PR" = null ]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "commit-artifacts: not inside a git work tree"
  git fetch -q origin >/dev/null 2>&1 || log "commit-artifacts: git fetch origin failed (continuing with what is known)"
  if [ -z "$BRANCH" ] || [ "$BRANCH" = null ]; then
    title=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.title // ""' 2>/dev/null)
    slug=$(printf '%s' "$title" | slugify)
    BRANCH="$PREFIX$ISSUE${slug:+-$slug}"
  fi
  case $BRANCH in
    "$DEFAULT"|master|main|swarm/state|*..*|-*|"") die "commit-artifacts: refusing to push to '$BRANCH'" ;;
  esac
  if git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
    git checkout -q -B "$BRANCH" "origin/$BRANCH" 2>/dev/null || die "commit-artifacts: cannot check out origin/$BRANCH"
  else
    git rev-parse -q --verify "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1 || die "commit-artifacts: origin/$DEFAULT is unknown; cannot create $BRANCH"
    git checkout -q -B "$BRANCH" "origin/$DEFAULT" 2>/dev/null || die "commit-artifacts: cannot create $BRANCH from origin/$DEFAULT"
    log "commit-artifacts: created $BRANCH from origin/$DEFAULT"
  fi
  mkdir -p "$DEST"
  if [ ! -f "$DEST/README.md" ]; then
    printf '# Swarm artifacts for #%s\n\nWritten by the swarm dispatcher and its roles for issue #%s of %s: documentation, never code. Each file is the artifact of one stage; `critic/` holds critic scores, `runs.json` the dispatch records. Staged artifacts land with the next role push.\n' \
      "$ISSUE" "$ISSUE" "$REPO" > "$DEST/README.md"
  fi
  while IFS=$'\t' read -r src name; do
    [ -n "$src" ] || continue
    mkdir -p "$DEST/$(dirname "$name")"
    cp "$src" "$DEST/$name"
    landed+=("$name")
  done < "$plan"
  git add -- "$DEST" || die "commit-artifacts: git add failed"
  if git diff --cached --quiet -- "$DEST"; then
    log "commit-artifacts: nothing new under $DEST — no commit"
    out mode commit; out branch "$BRANCH"; out landed ""; out staged ""; out docs_head "$(git rev-parse HEAD)"
    printf 'mode=commit\nbranch=%s\nlanded=\ndocs_head=%s\n' "$BRANCH" "$(git rev-parse HEAD)"
    rm -f "$plan" "$runs"
    exit 0
  fi
  "${G[@]}" commit -q -m "docs(swarm): #$ISSUE ${STAGE:-stage} artifacts" --trailer "Swarm-Issue: #$ISSUE" \
    || die "commit-artifacts: git commit failed"
  err=$(tmpf .err) || die "commit-artifacts: no temp dir"
  if ! git push -q origin "HEAD:refs/heads/$BRANCH" 2> "$err"; then
    log "commit-artifacts: push to refs/heads/$BRANCH refused: $(tail -n 2 "$err" | tr '\n' ' ')"
    rm -f "$err" "$plan" "$runs"
    exit 1
  fi
  rm -f "$err" "$plan" "$runs"
  head=$(git rev-parse HEAD)
  log "commit-artifacts: pushed ${#landed[@]} file(s) to $BRANCH ($head)"
  out mode commit; out branch "$BRANCH"; out landed "${landed[*]}"; out staged ""; out docs_head "$head"
  printf 'mode=commit\nbranch=%s\nlanded=%s\ndocs_head=%s\n' "$BRANCH" "${landed[*]}" "$head"
  exit 0
fi

# ── staging mode ────────────────────────────────────────────────────────────────

require_env SWARM_STATE_KEY
if [ "${STAGE_NOTHING:-0}" = 1 ]; then
  # the last write role before merge: nothing lands after it; what is missing on head is reported
  while IFS=$'\t' read -r src name; do
    [ -n "$src" ] || continue
    if git rev-parse -q --verify "$(S '.head'):$DEST/$name" >/dev/null 2>&1; then landed+=("$name"); else log "commit-artifacts: $name is not on the pushed head and nothing lands after this role"; fi
  done < "$plan"
  rm -f "$plan" "$runs"
  out mode stage; out branch "$BRANCH"; out landed "${landed[*]}"; out staged ""
  printf 'mode=stage\nbranch=%s\nlanded=%s\nstaged=\n' "$BRANCH" "${landed[*]}"
  exit 0
fi
on_head() { # <name> <src>: the pushed head already carries this content
  local h=${HEAD:-} blob
  [ -n "$h" ] || h=$(S '.head')
  [ -n "$h" ] || return 1
  blob=$(git rev-parse -q --verify "$h:$DEST/$1" 2>/dev/null) || return 1
  [ "$blob" = "$(git hash-object "$2")" ]
}
rc=0
while IFS=$'\t' read -r src name; do
  [ -n "$src" ] || continue
  if on_head "$name" "$src"; then
    log "commit-artifacts: $name is already on the pushed head — not staged"
    landed+=("$name")
    continue
  fi
  if "$SWARM_LIB/state.sh" stage-pending "$ISSUE" "$src" "$name" >/dev/null; then
    staged+=("$name")
  else
    log "commit-artifacts: staging of $name failed"
    rc=1
  fi
done < "$plan"
rm -f "$plan" "$runs"
out mode stage; out branch "$BRANCH"; out landed "${landed[*]}"; out staged "${staged[*]}"
printf 'mode=stage\nbranch=%s\nlanded=%s\nstaged=%s\n' "$BRANCH" "${landed[*]}" "${staged[*]}"
exit $rc
