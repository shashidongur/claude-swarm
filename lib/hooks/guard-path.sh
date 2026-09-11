#!/usr/bin/env bash
# guard-path.sh — PreToolUse hook for Write | Edit | MultiEdit (spec §13.2, §7.1).
#
# Reads the tool-call JSON on stdin, resolves `.tool_input.file_path` against the
# workspace (`realpath -m`, so `..` and symlinks cannot escape), and exits 2 with the
# reason on stderr — Claude Code then refuses the call and shows the reason to the
# model — unless the path is
#   1. inside the workspace,
#   2. under one of the SWARM_WRITE_ROOTS (colon-separated; `.` = the whole tree — but
#      `.swarm-run/` is reachable only through an explicit `.swarm-run/…` root, so a
#      write-class role with root `.` still cannot touch the brief, the state snapshot,
#      the critic score or the evidence), and
#   3. neither under a SWARM_PROTECTED glob nor a SWARM_DENY path/glob (colon-separated),
# and never `.git/**` or `.swarm/**` (the git directory and the swarm's own code).
#
# The workspace is SWARM_WORKSPACE, else CLAUDE_PROJECT_DIR, else the tool call's `cwd`,
# else the current directory. Everything fails closed: no file_path, no roots, an
# unreadable common.sh — all deny. This hook is defence in depth; G29's diff check in
# advance is the perimeter, and its list (".swarm-run/**" must never be committed) is
# deliberately not this list (".swarm-run/artifacts/**" must be written).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sh" && pwd)"

deny() {
  printf 'swarm guard-path: denied — %s\n' "$1" >&2
  exit 2
}

if [ -r "$SWARM_LIB/common.sh" ]; then
  # shellcheck source=lib/sh/common.sh
  . "$SWARM_LIB/common.sh"
else
  deny "cannot load $SWARM_LIB/common.sh (the swarm tree is missing or unreadable)"
fi

input=$(cat 2>/dev/null) || input=""
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || fp=""
[ -n "$fp" ] || deny "the tool input names no file_path"

ws=${SWARM_WORKSPACE:-${CLAUDE_PROJECT_DIR:-}}
if [ -z "$ws" ]; then
  ws=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || ws=""
fi
[ -n "$ws" ] || ws=$PWD
ws=$(realpath -m -- "$ws" 2>/dev/null) || deny "cannot resolve the workspace"

case $fp in
  /*) abs=$(realpath -m -- "$fp" 2>/dev/null) || abs="" ;;
  *)  abs=$(realpath -m -- "$ws/$fp" 2>/dev/null) || abs="" ;;
esac
[ -n "$abs" ] || deny "cannot resolve $fp"
case $abs in
  "$ws"/*) rel=${abs#"$ws"/} ;;
  *) deny "$fp resolves outside the workspace" ;;
esac

case $rel in
  .git|.git/*|.swarm|.swarm/*) deny "$rel — the git directory and the swarm tree are never written by a role" ;;
esac

roots=${SWARM_WRITE_ROOTS:-}
[ -n "$roots" ] || deny "no write root is configured (SWARM_WRITE_ROOTS is empty)"
allowed=0
IFS=: read -r -a rootlist <<< "$roots"
for r in "${rootlist[@]}"; do
  r=${r#./}
  r=${r%/}
  [ -n "$r" ] || continue
  if [ "$r" = "." ]; then
    case $rel in
      .swarm-run|.swarm-run/*) ;;
      *) allowed=1 ;;
    esac
  elif [ "$rel" = "$r" ] || [ "${rel#"$r"/}" != "$rel" ]; then
    allowed=1
  fi
  [ $allowed -eq 1 ] && break
done
[ $allowed -eq 1 ] || deny "$rel is not under a write root (roots: $roots)"

if [ -n "${SWARM_PROTECTED:-}" ]; then
  IFS=: read -r -a prot <<< "$SWARM_PROTECTED"
  if matches_glob "$rel" "${prot[@]}"; then
    deny "$rel is a protected path"
  fi
fi

if [ -n "${SWARM_DENY:-}" ]; then
  IFS=: read -r -a denylist <<< "$SWARM_DENY"
  if matches_glob "$rel" "${denylist[@]}"; then
    deny "$rel is written by the dispatcher, not by a role"
  fi
fi

exit 0
