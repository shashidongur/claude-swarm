#!/usr/bin/env bash
# commands.sh — the `/swarm` grammar (spec §6.1) and who may use it (§6.2).
#
#   commands.sh parse < first-line.txt
#       Parses the first non-empty line of a comment (or review body) and prints one
#       JSON object: {verb, args, gate?, stage?, reason?, force?, path?}.
#         verb ∈ start approve reject resume redo skip park drop hands-off path status
#         a line that is not a /swarm command      → {"verb": null}
#         /swarm <unknown>                         → {"verb": "unknown", "input": "<word>"}
#         /swarm approve release                   → {"verb": "approve", "gate": "release"} (the caller says "merge the PR")
#       Argument errors (a reject without a reason, a redo without a stage, a path
#       that is neither full nor short) come back as {"verb": …, "error": "…"} so the
#       caller replies with the reason instead of guessing. Everything after the first
#       line is data (GUARD) and never reaches this parser.
#   commands.sh allowed <verb> <gate> <login> [<config.json>]
#       Exit 0 when the login may run the verb: approve/reject use the gate's list,
#       budget and every other verb use approvers.default (falling back to the
#       repository owner on a user-owned repository). Exit 2 when no approver list
#       can be resolved at all (an org-owned repository without config, §6.2).
#   commands.sh verbs
#       The verb list, one per line (for the "unknown verb" reply).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

VERBS="start approve reject resume redo skip park drop hands-off path status"
GATES="requirements architecture release question confidence budget"
STAGES="triage requirements design architecture build test security release retro"

has_word() { # <word> <list>
  local w=$1 x
  for x in $2; do [ "$x" = "$w" ] && return 0; done
  return 1
}

cmd_parse() {
  local line verb rest
  # the first non-empty line, trimmed; CRLF tolerated
  line=$(tr -d '\r' | sed -n -E '/^[[:space:]]*$/!{p;q}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if ! [[ $line =~ ^/swarm([[:space:]]+([a-z-]+)([[:space:]]+(.*))?)?[[:space:]]*$ ]]; then
    printf '{"verb": null}\n'
    return 0
  fi
  verb=${BASH_REMATCH[2]:-}
  rest=${BASH_REMATCH[4]:-}
  rest=$(printf '%s' "$rest" | sed -E 's/[[:space:]]+$//')
  if [ -z "$verb" ]; then
    jq -n '{verb: "unknown", input: ""}'
    return 0
  fi
  if ! has_word "$verb" "$VERBS"; then
    jq -n --arg v "$verb" '{verb: "unknown", input: $v}'
    return 0
  fi
  local w1 w2
  read -r w1 w2 _ <<< "$rest"
  case $verb in
    start)
      # start [full|short] [force] — in any order
      local path="" force=false w
      for w in $rest; do
        case $w in
          full|short) path=$w ;;
          force) force=true ;;
          *) jq -n --arg v "$verb" --arg a "$rest" --arg w "$w" '{verb: $v, args: $a, error: ("unexpected argument \"" + $w + "\" — /swarm start [full|short] [force]")}'; return 0 ;;
        esac
      done
      jq -n --arg v "$verb" --arg a "$rest" --arg p "$path" --argjson f "$force" \
        '{verb: $v, args: $a, force: $f} + (if $p != "" then {path: $p} else {} end)'
      ;;
    approve)
      if [ -z "$rest" ]; then
        jq -n --arg v "$verb" '{verb: $v, args: ""}'
      elif has_word "$w1" "$GATES" && [ -z "$w2" ]; then
        jq -n --arg v "$verb" --arg a "$rest" --arg g "$w1" '{verb: $v, args: $a, gate: $g}'
      else
        jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a, error: ("unknown gate \"" + $a + "\" — /swarm approve [requirements|architecture|confidence|budget]")}'
      fi
      ;;
    reject)
      if [ ${#rest} -lt 3 ]; then
        jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a, error: "a reason of at least 3 characters is required — /swarm reject <why>"}'
      else
        jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a, reason: $a}'
      fi
      ;;
    redo|skip)
      if [ -z "$w1" ]; then
        jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a, error: ("a stage is required — /swarm " + $v + " <stage> [why]")}'
      elif ! has_word "$w1" "$STAGES"; then
        jq -n --arg v "$verb" --arg a "$rest" --arg s "$w1" --arg st "$STAGES" '{verb: $v, args: $a, error: ("unknown stage \"" + $s + "\" — stages: " + $st)}'
      else
        local reason
        reason=$(printf '%s' "$rest" | sed -E 's/^[a-z-]+[[:space:]]*//')
        jq -n --arg v "$verb" --arg a "$rest" --arg s "$w1" --arg r "$reason" \
          '{verb: $v, args: $a, stage: $s} + (if $r != "" then {reason: $r} else {} end)'
      fi
      ;;
    path)
      case $w1 in
        full|short)
          [ -z "$w2" ] && { jq -n --arg v "$verb" --arg a "$rest" --arg p "$w1" '{verb: $v, args: $a, path: $p}'; return 0; } ;;
      esac
      jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a, error: "/swarm path full|short"}'
      ;;
    resume|park|drop|hands-off|status)
      jq -n --arg v "$verb" --arg a "$rest" '{verb: $v, args: $a}'
      ;;
  esac
}

cmd_allowed() {
  local verb=${1:-} gate=${2:-} login=${3:-} cfg=${4:-} list
  [ -n "$verb" ] && [ -n "$login" ] || die "usage: commands.sh allowed <verb> <gate> <login> [<config.json>]"
  [ -n "$cfg" ] && export CONFIG_JSON=$cfg
  case $verb in
    approve|reject)
      case $gate in
        requirements|architecture|release|confidence) ;;
        *) gate=default ;;
      esac ;;
    *) gate=default ;;
  esac
  list=$(approvers_for "$gate") || exit 2
  printf '%s\n' "$list" | grep -qixF -- "$login"
}

case ${1:-} in
  parse) cmd_parse ;;
  allowed) shift; cmd_allowed "$@" ;;
  verbs) printf '%s\n' $VERBS ;;
  *) sed -n '2,24p' "$0" >&2; exit 1 ;;
esac
