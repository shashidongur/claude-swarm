#!/usr/bin/env bash
# guard-bash.sh — PreToolUse hook for Bash (spec §13.2, §9.6).
#
# Reads the tool-call JSON on stdin and exits 2 (the reason on stderr; Claude Code
# refuses the call) when `.tool_input.command` matches any denied pattern:
#   SWARM_BASH_DENY   ERE patterns, one per line (exported by begin.sh from
#                     pipeline.json's `bash_deny`), else
#   pipeline.json     `.bash_deny` of the swarm tree this hook lives in, else
#   the built-in list below (the same patterns, frozen).
# The command reaches grep on stdin, never on a command line. A call with no command
# is denied (fail closed). Documented as bypassable — `bash -c "$(base64 -d …)"` is one
# line away — which is why the job token, G29 and G35 are the perimeter, not this.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sh" && pwd)"

deny() {
  printf 'swarm guard-bash: denied — %s\n' "$1" >&2
  exit 2
}

if [ -r "$SWARM_LIB/common.sh" ]; then
  # shellcheck source=lib/sh/common.sh
  . "$SWARM_LIB/common.sh"
else
  deny "cannot load $SWARM_LIB/common.sh (the swarm tree is missing or unreadable)"
fi

builtin_deny() {
  cat <<'EOF'
pulls/[0-9]+/merge
--method
-X ?(PUT|PATCH|DELETE|POST)
push .*:(refs/heads/)?(main|master|swarm/state)
push .*\+
push --force
push -f\b
curl|wget .*api\.github\.com
git -C \.swarm
\.swarm/lib
\$RUNNER_TEMP|claude-execution-output
(^|[;&|] *)(env|printenv)( |$)
/proc/self/environ
EOF
}

input=$(cat 2>/dev/null) || input=""
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
[ -n "$cmd" ] || deny "the tool input carries no command"

pf=$(tmpf .deny) || deny "cannot create a temporary file"
trap 'rm -f "$pf"' EXIT
if [ -n "${SWARM_BASH_DENY:-}" ]; then
  printf '%s\n' "$SWARM_BASH_DENY" > "$pf"
elif [ -f "$SWARM_ROOT/pipeline.json" ] && jq -e '.bash_deny | type == "array" and length > 0' "$SWARM_ROOT/pipeline.json" >/dev/null 2>&1; then
  jq -r '.bash_deny[]' "$SWARM_ROOT/pipeline.json" > "$pf"
else
  builtin_deny > "$pf"
fi

export LC_ALL=C
while IFS= read -r p || [ -n "$p" ]; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$cmd" | grep -qE -e "$p"; then
    deny "the command matches the denied pattern /$p/"
  fi
done < "$pf"

exit 0
