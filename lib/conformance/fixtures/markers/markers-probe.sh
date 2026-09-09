#!/usr/bin/env bash
# markers-probe.sh — drives the marker/sanitise helpers for the markers/ cases:
#   roundtrip                 render a stage marker with `marker`, parse every field back with `marker_get`
#   get <field>               `marker_get <field>` over stdin (empty for a v1 marker)
#   check <result.json> [jq args…]   lib/jq/result-check.jq → the errors array (one line)
#   find <issue> <kind> [k=v…]       `find_comment` with `marker_pred`; prints the comment id or RC=1
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

cmd=${1:-}
shift || true
case $cmd in
  roundtrip)
    m=$(marker stage issue=7 stage=build role=dev:app attempt=1 key=7:build:dev:app:1 run=424242 status=running verdict=pass head=f54b320c1e3d4a5b6c7d8e9f0a1b2c3d4e5f6a7b model=claude-sonnet-5)
    printf 'MARKER %s\n' "$m"
    for f in kind issue stage role attempt key run status verdict head model at; do
      printf 'PARSED %s=%s\n' "$f" "$(printf '%s\n' "$m" | marker_get "$f")"
    done
    ;;
  get)
    v=$(marker_get "${1:?field}")
    printf 'VALUE=[%s]\n' "$v"
    ;;
  check)
    f=${1:?result file}
    shift
    jq -c -f "$SWARM_ROOT/lib/jq/result-check.jq" "$@" "$f"
    ;;
  find)
    issue=${1:?issue}
    kind=${2:?kind}
    shift 2
    if c=$(find_comment "$issue" "$(marker_pred "$kind" "$@")"); then
      printf 'FOUND id=%s\n' "$(printf '%s' "$c" | jq -r .id)"
    else
      printf 'RC=1\n'
    fi
    ;;
  *) die "markers-probe: unknown command '$cmd'" ;;
esac
