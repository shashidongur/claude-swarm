#!/usr/bin/env bash
# redact.sh: stdin → stdout with every secret the job knows replaced by `***`.
#
# What is replaced (§11.4):
#   - the value of every secret-bearing variable in the environment:
#     CLAUDE_CODE_OAUTH_TOKEN, ROLE_GH_TOKEN, RETRY_GH_TOKEN, CRITIC_GH_TOKEN,
#     SWARM_TOKEN, SWARM_STATE_KEY, GH_TOKEN, GITHUB_TOKEN
#   - every value listed in REDACT_VALUES (newline-separated)
#   - the token shapes ghs_/ghp_/gho_/ghu_/ghr_[A-Za-z0-9]{20,}, github_pat_[A-Za-z0-9_]{20,},
#     sk-ant-[A-Za-z0-9_-]{20,} and x-access-token:<anything>@ (the credential part only)
# Values shorter than 6 characters are ignored so a short placeholder cannot blank a
# whole transcript. Runs byte-wise (LC_ALL=C) so a transcript with invalid UTF-8
# still redacts.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

export LC_ALL=C

vals=()
add_val() {
  local v=$1
  [ ${#v} -ge 6 ] || return 0
  case $v in *$'\n'*) return 0 ;; esac
  vals+=("$v")
}

for name in CLAUDE_CODE_OAUTH_TOKEN ROLE_GH_TOKEN RETRY_GH_TOKEN CRITIC_GH_TOKEN SWARM_TOKEN SWARM_STATE_KEY GH_TOKEN GITHUB_TOKEN; do
  v=${!name:-}
  [ -n "$v" ] && add_val "$v"
done
if [ -n "${REDACT_VALUES:-}" ]; then
  while IFS= read -r v; do
    [ -n "$v" ] && add_val "$v"
  done <<< "$REDACT_VALUES"
fi

exprs=()
# Longest values first, so a value that contains another is replaced whole.
if [ ${#vals[@]} -gt 0 ]; then
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    esc=$(printf '%s' "$v" | sed -e 's/[]\/$*.^[]/\\&/g')
    exprs+=(-e "s/$esc/***/g")
  done < <(printf '%s\n' "${vals[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
fi

if [ ${#exprs[@]} -gt 0 ]; then
  sed "${exprs[@]}"
else
  cat
fi | sed -E \
  -e 's/gh[spour]_[A-Za-z0-9]{20,}/***/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/***/g' \
  -e 's/sk-ant-[A-Za-z0-9_-]{20,}/***/g' \
  -e 's/x-access-token:[^@[:space:]]+@/x-access-token:***@/g' \
  -e 's/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*)([Bb]asic|[Bb]earer|[Tt]oken)[[:space:]]+[A-Za-z0-9+\/=_.~-]{8,}/\1\2 ***/g'
