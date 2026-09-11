#!/usr/bin/env bash
# render-probe.sh headers — the state header line of every state fixture, for the
# status-phrase case (one script call, four documents).
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"
case ${1:-} in
  headers)
    for f in valid-at-gate valid-blocked-fire valid-queued-next valid-waiting-evidence; do
      "$SWARM_LIB/render.sh" state "$SWARM_ROOT/lib/conformance/fixtures/schema/state/$f.json" - --arg at 2026-09-06T14:41:39Z | head -1
    done ;;
  *) die "render-probe: unknown command" ;;
esac
