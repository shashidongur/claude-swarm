#!/usr/bin/env bash
# scenario.sh — builds a git scenario in the harness project (a bare origin, the
# integration branch, a base commit, the attempt's commits), patches the head into
# .swarm-run/result.json, writes the gh fixtures that must carry the real sha, and
# then runs lib/sh/validate-result.sh with the remaining arguments. Knobs (env):
#
#   SC_BRANCH            integration branch (default claude/issue-7-live-session-capacity)
#   SC_BASE_FILES        "path=content" lines committed on the branch before the base
#                        (content: `\n` escapes decoded; "@DELETE" deletes)
#   SC_FILES             the same, committed as the attempt (one commit)
#   SC_TRAILER           0 → the attempt commit carries no Swarm-Issue trailer
#   SC_RESULT_HEAD       head (default) | base | keep — what .head in result.json becomes
#   SC_BASE_NOT_ANCESTOR 1 → BASE_SHA names a side commit that is not an ancestor
#   SC_MOVE_ORIGIN       1 → origin's branch gets one more commit the checkout does not have
#   SC_DIRTY             "path=content" untracked file left in the tree at the end
#   SC_SYMLINK           "link=target" symlink created at the end (relative paths)
#   SC_PR_VIEW           1 → cmd/pr-view-<SC_PR_NUMBER>.json with headRefOid = the head
#   SC_PR_NUMBER         default 9;  SC_PR_BASE default main;  SC_PR_DRAFT default false
#   SC_PR_BODY           default "Closes #7\n\nSwarm-Issue: #7"
#   SC_PR_LIST           1 → cmd/pr-list.json with one open PR (draft, base SC_PR_BASE)
#   SC_NO_ORIGIN         1 → no remote at all (the checkout only)
#
# Exports BRANCH, BASE_SHA and HEAD for the validator unless already set, prints one
# `SCENARIO:` line, and execs validate-result.sh.
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

G=(git -c user.name=swarm-harness -c user.email=harness@example.invalid)
branch=${SC_BRANCH:-claude/issue-7-live-session-capacity}
issue=${ISSUE:-7}

write_files() { # <spec>: "path=content" lines
  local line p c
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    p=${line%%=*}
    c=${line#*=}
    if [ "$c" = "@DELETE" ]; then
      rm -f -- "$p"
      git rm -q --cached -- "$p" 2>/dev/null || true
      continue
    fi
    mkdir -p "$(dirname "$p")"
    printf '%b' "$c" > "$p"
    git add -- "$p"
  done <<< "$1"
}

commit() { # <message> [trailer:1|0]
  if [ "${2:-1}" = 1 ]; then
    "${G[@]}" commit -q --allow-empty -m "$1" --trailer "Swarm-Issue: #$issue"
  else
    "${G[@]}" commit -q --allow-empty -m "$1"
  fi
}

if [ "${SC_NO_ORIGIN:-0}" != 1 ]; then
  git init -q --bare "$RUNNER_TEMP/origin.git"
  git remote add origin "$RUNNER_TEMP/origin.git"
  git push -q origin main 2>/dev/null || die "scenario: cannot push main"
fi

git checkout -q -b "$branch"
if [ -n "${SC_BASE_FILES:-}" ]; then
  write_files "$SC_BASE_FILES"
  commit "base files"
fi
base=$(git rev-parse HEAD)
[ "${SC_NO_ORIGIN:-0}" = 1 ] || git push -q origin "$branch" 2>/dev/null

if [ "${SC_BASE_NOT_ANCESTOR:-0}" = 1 ]; then
  git checkout -q -b side main
  printf 'side\n' > side.txt
  git add side.txt
  commit "side commit"
  base=$(git rev-parse HEAD)
  git checkout -q "$branch"
fi

if [ -n "${SC_FILES:-}" ]; then
  write_files "$SC_FILES"
  commit "attempt: implement" "${SC_TRAILER:-1}"
  [ "${SC_NO_ORIGIN:-0}" = 1 ] || git push -q origin "$branch" 2>/dev/null
fi
head=$(git rev-parse HEAD)

if [ "${SC_MOVE_ORIGIN:-0}" = 1 ]; then
  git checkout -q -b moved
  printf 'moved\n' > moved.txt
  git add moved.txt
  commit "someone else pushed"
  git push -q origin "moved:$branch" 2>/dev/null
  git checkout -q "$branch"
  git branch -q -D moved
fi

[ "${SC_NO_ORIGIN:-0}" = 1 ] || git fetch -q origin 2>/dev/null

if [ -f .swarm-run/result.json ]; then
  case ${SC_RESULT_HEAD:-head} in
    head) jq --arg h "$head" '.head = $h' .swarm-run/result.json > .swarm-run/result.json.tmp && mv .swarm-run/result.json.tmp .swarm-run/result.json ;;
    base) jq --arg h "$base" '.head = $h' .swarm-run/result.json > .swarm-run/result.json.tmp && mv .swarm-run/result.json.tmp .swarm-run/result.json ;;
    keep) ;;
  esac
fi

if [ "${SC_PR_VIEW:-0}" = 1 ]; then
  mkdir -p "$SWARM_FAKE_GH/cmd"
  jq -n --arg h "$head" --arg base "${SC_PR_BASE:-main}" --argjson draft "${SC_PR_DRAFT:-false}" \
    --arg body "$(printf '%b' "${SC_PR_BODY:-Closes #7\\n\\nSwarm-Issue: #7}")" --argjson n "${SC_PR_NUMBER:-9}" \
    '{number: $n, isDraft: $draft, baseRefName: $base, headRefOid: $h, body: $body, files: []}' \
    > "$SWARM_FAKE_GH/cmd/pr-view-${SC_PR_NUMBER:-9}.json"
fi
if [ "${SC_PR_LIST:-0}" = 1 ]; then
  mkdir -p "$SWARM_FAKE_GH/cmd"
  jq -n --arg base "${SC_PR_BASE:-main}" --argjson draft "${SC_PR_DRAFT:-true}" --argjson n "${SC_PR_NUMBER:-9}" \
    '[{number: $n, isDraft: $draft, baseRefName: $base}]' > "$SWARM_FAKE_GH/cmd/pr-list.json"
fi

if [ -n "${SC_DIRTY:-}" ]; then
  p=${SC_DIRTY%%=*}
  mkdir -p "$(dirname "$p")"
  printf '%b' "${SC_DIRTY#*=}" > "$p"
fi
if [ -n "${SC_SYMLINK:-}" ]; then
  l=${SC_SYMLINK%%=*}
  mkdir -p "$(dirname "$l")"
  ln -s "${SC_SYMLINK#*=}" "$l"
fi

export BRANCH=${BRANCH:-$branch} BASE_SHA=${BASE_SHA:-$base} HEAD=${HEAD:-$head}
printf 'SCENARIO: branch=%s base=%s head=%s\n' "$BRANCH" "$BASE_SHA" "$HEAD"
exec "$SWARM_LIB/validate-result.sh" "$@"
