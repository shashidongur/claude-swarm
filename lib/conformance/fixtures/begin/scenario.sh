#!/usr/bin/env bash
# scenario.sh — runs begin.sh the way a run job does: the swarm tree packed into
# ./.swarm by pack-tree.sh (state read through the shim's state store), roles
# installed by install-roles.sh, then .swarm/lib/sh/begin.sh; prints PROBE lines the
# cases assert and leaves the tree writable again so the harness can clean up.
# Knobs (env):
#
#   SC_BRANCH        integration branch (default claude/issue-7-live-session-capacity)
#   SC_NO_ORIGIN     1 → no remote, no branch (the checkout only)
#   SC_MAIN_FILES    "path=content" lines committed on main before branching (`\n` decoded)
#   SC_BRANCH_FILES  "path=content" lines committed on the branch (the planted files)
#   SC_CONFIG        config JSON relative to lib/conformance/ (default fixtures/config/user-owned.json)
#   SC_PACK          0 → run $SWARM_ROOT/lib/sh/begin.sh directly (no packed tree)
#   SC_INSTALL       0 → skip install-roles.sh
#   SC_BEGIN_ENV     extra "KEY=VALUE" lines exported before begin.sh
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

G=(git -c user.name=swarm-harness -c user.email=harness@example.invalid)
branch=${SC_BRANCH:-claude/issue-7-live-session-capacity}
issue=${ISSUE:-7}
conf="$SWARM_ROOT/lib/conformance"

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

if [ -n "${SC_MAIN_FILES:-}" ]; then
  write_files "$SC_MAIN_FILES"
  "${G[@]}" commit -q -m "main files"
fi
if [ "${SC_NO_ORIGIN:-0}" != 1 ]; then
  git init -q --bare "$RUNNER_TEMP/origin.git"
  git remote add origin "$RUNNER_TEMP/origin.git"
  git push -q origin main 2>/dev/null || die "scenario: cannot push main"
  git checkout -q -b "$branch"
  if [ -n "${SC_BRANCH_FILES:-}" ]; then
    write_files "$SC_BRANCH_FILES"
    "${G[@]}" commit -q -m "branch files" --trailer "Swarm-Issue: #$issue"
  fi
  git push -q origin "$branch" 2>/dev/null
  git checkout -q main
  git fetch -q origin 2>/dev/null
fi

state=$(tmpf .state)
gh api "repos/$REPO/contents/issues/$issue.json?ref=swarm/state" --jq .content | base64 -d > "$state" || die "scenario: no state for #$issue in the shim"
cfg="$conf/${SC_CONFIG:-fixtures/config/user-owned.json}"
[ -f "$cfg" ] || die "scenario: config $cfg not found"

if [ "${SC_PACK:-1}" = 1 ]; then
  STATE_JSON=$state CONFIG_JSON=$cfg "$SWARM_LIB/pack-tree.sh" --out .swarm --issue "$issue" >/dev/null || die "scenario: pack-tree failed"
  begin=".swarm/lib/sh/begin.sh"
  if [ "${SC_INSTALL:-1}" = 1 ]; then
    .swarm/lib/sh/install-roles.sh >/dev/null || die "scenario: install-roles failed"
  fi
else
  begin="$SWARM_LIB/begin.sh"
  export STATE_JSON=$state CONFIG_JSON=$cfg
fi

if [ -n "${SC_BEGIN_ENV:-}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    export "${line?}"
  done <<< "$SC_BEGIN_ENV"
fi

env -u SWARM_ROOT -u SWARM_LIB "$begin"
rc=$?
printf 'PROBE: begin exit %s\n' "$rc"
for f in .claude/settings.json CLAUDE.md .mcp.json .claude/agents/dev.md .swarm-run/brief.md docs/swarm/$issue/review-app-a1.md installed.flag; do
  if [ -e "$f" ]; then printf 'PROBE: %s exists\n' "$f"; else printf 'PROBE: %s absent\n' "$f"; fi
done
if [ -d .swarm ]; then
  printf 'PROBE: swarm writable files: %s\n' "$(find .swarm -type f -perm -u+w | wc -l | tr -d ' ')"
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'PROBE: last commit: %s\n' "$(git log -1 --format=%s 2>/dev/null)"
  if git log -1 --format=%B 2>/dev/null | grep -q "^Swarm-Issue: #$issue"; then printf 'PROBE: trailer yes\n'; else printf 'PROBE: trailer no\n'; fi
  if [ "${SC_NO_ORIGIN:-0}" != 1 ] && git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
    printf 'PROBE: ahead of origin: %s\n' "$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null)"
  fi
  printf 'PROBE: porcelain: %s\n' "$(git status --porcelain --untracked-files=all 2>/dev/null | tr '\n' ' ')"
fi
if [ -n "${GITHUB_ENV:-}" ] && [ -f "$GITHUB_ENV" ]; then
  printf 'PROBE: github-env keys: %s\n' "$(grep -oE '^[A-Z_]+(=|<<)' "$GITHUB_ENV" | sed 's/[=<]*$//' | tr '\n' ' ')"
fi
[ -d .swarm ] && chmod -R u+w .swarm
exit $rc
