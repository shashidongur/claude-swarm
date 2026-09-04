#!/usr/bin/env bash
# Conformance test for the mention grammar in lib/ROUTING.md.
#
# Every project's dispatch workflow implements this parsing itself, in whatever the
# workflow language is. This script is the definition of correct: run it against your
# implementation's logic before wiring a new project up, and any divergence is a bug in
# that workflow, not in the grammar.
#
#   ./lib/dispatch-conformance.sh <project-prefix>      e.g.  ./lib/dispatch-conformance.sh acme

set -uo pipefail
PREFIX="${1:-acme}-swarm"
ROLES="product-owner|architect|designer|implementer|reviewer|test-engineer"
fails=0

resolve() {
  printf '%s' "$1" > /tmp/_swarm_body.txt
  if ! grep -qE "@${PREFIX}-[a-z-]+" /tmp/_swarm_body.txt; then echo "REJECT:no-mention"; return; fi
  local n role next
  n=$(grep -oE "@${PREFIX}-[a-z-]+" /tmp/_swarm_body.txt | sort -u | wc -l | tr -d ' ')
  if [ "$n" != "1" ]; then echo "REJECT:multi($n)"; return; fi
  role=$(grep -oE "@${PREFIX}-[a-z-]+" /tmp/_swarm_body.txt | head -1 | sed "s/@${PREFIX}-//")
  if ! echo "$role" | grep -qE "^(${ROLES})$"; then echo "REJECT:unknown($role)"; return; fi
  if grep -q 'kind=stage' /tmp/_swarm_body.txt; then
    next=$(grep -oE 'next=[a-z-]+' /tmp/_swarm_body.txt | head -1 | cut -d= -f2)
    if [ "$next" != "$role" ]; then echo "REJECT:mismatch(next=$next vs @$role)"; return; fi
  fi
  if grep -qE "role=${role}[ |]" /tmp/_swarm_body.txt; then echo "REJECT:self-refire"; return; fi
  echo "$role"
}

check() {
  local got; got=$(resolve "$2")
  if [ "$got" = "$3" ]; then printf "  PASS   %-30s -> %s\n" "$1" "$got"
  else printf "  FAIL   %-30s -> %s (want %s)\n" "$1" "$got" "$3"; fails=$((fails+1)); fi
}

check "normal handoff" "**@${PREFIX}-test-engineer** — aim at the lapsed case
<!-- swarm: v1 | kind=stage | role=reviewer | next=test-engineer | issue=44 | verdict=pass -->" "test-engineer"
check "self-dispatch" "**@${PREFIX}-reviewer** — over to me
<!-- swarm: v1 | kind=stage | role=reviewer | next=reviewer | issue=44 -->" "REJECT:self-refire"
check "mention/marker disagree" "**@${PREFIX}-implementer** — fix it
<!-- swarm: v1 | kind=stage | role=reviewer | next=test-engineer | issue=44 -->" "REJECT:mismatch(next=test-engineer vs @implementer)"
check "fan-out" "**@${PREFIX}-implementer** — the guard
**@${PREFIX}-test-engineer** — the lapsed case" "REJECT:multi(2)"
check "unknown role" "**@${PREFIX}-deployer** — ship it" "REJECT:unknown(deployer)"
check "plain human comment" "This still looks wrong, can someone check?" "REJECT:no-mention"
check "human starts the chain" "@${PREFIX}-product-owner please pick this up" "product-owner"
check "foreign project prefix" "**@otherproj-swarm-reviewer** — not ours" "REJECT:no-mention"

echo
if [ "$fails" -eq 0 ]; then echo "  8/8 conformant"; else echo "  $fails FAILING"; exit 1; fi
