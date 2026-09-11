#!/usr/bin/env bash
# state-probe.sh <mode> — multi-step state.sh scenarios the state/ cases run
# (sign/verify round trip, the pending-artifact lifecycle, create-twice, billing).
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"
ST="$SWARM_LIB/state.sh"
ISSUE=${ISSUE:-7}

case ${1:-} in
  sign-roundtrip)
    doc='{"v":2,"issue":7,"repo":"o/r","status":"queued","nested":{"z":1,"a":[1,2]}}'
    signed=$(printf '%s' "$doc" | "$ST" sign) || die "sign failed"
    printf '%s' "$signed" | "$ST" verify && echo "PROBE: signed document verifies"
    # key order and whitespace do not matter — the canonical form is signed
    printf '%s' "$signed" | jq -c 'to_entries | reverse | from_entries' | "$ST" verify && echo "PROBE: reordered document verifies"
    printf '%s' "$signed" | jq '.status = "done"' | "$ST" verify; echo "PROBE: tampered rc=$?"
    printf '%s' "$signed" | jq 'del(.sig)' | "$ST" verify; echo "PROBE: unsigned rc=$?"
    printf '%s' "$signed" | SWARM_STATE_KEY=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff "$ST" verify; echo "PROBE: foreign key rc=$?"
    sig1=$(printf '%s' "$signed" | jq -r .sig); sig2=$(printf '%s' "$doc" | "$ST" sign | jq -r .sig)
    [ "$sig1" = "$sig2" ] && echo "PROBE: signing is deterministic"
    ;;
  pending-lifecycle)
    printf '# review\n\nfinding one\n' > review-app-a1.md
    mkdir -p critic && printf '{"score": 80}\n' > critic/architecture-a1.json
    "$ST" stage-pending "$ISSUE" review-app-a1.md || die "stage 1 failed"
    "$ST" stage-pending "$ISSUE" critic/architecture-a1.json critic/architecture-a1.json || die "stage 2 failed"
    "$ST" read "$ISSUE" | jq -c '.pending_artifacts | map(.file)' | sed 's/^/PROBE: pending after stage /'
    mkdir -p landing
    "$ST" copy-pending "$ISSUE" landing || die "copy failed"
    [ -f landing/review-app-a1.md ] && [ -f landing/critic/architecture-a1.json ] && echo "PROBE: both files copied"
    [ -f "$SWARM_FAKE_GH/state/pending-$ISSUE-review-app-a1.md" ] && echo "PROBE: staged file still present after copy"
    "$ST" copy-pending "$ISSUE" landing2 || die "second copy failed"
    [ -f landing2/review-app-a1.md ] && echo "PROBE: a second copy still works"
    "$ST" clear-pending "$ISSUE" review-app-a1.md || die "clear failed"
    [ -f "$SWARM_FAKE_GH/state/pending-$ISSUE-review-app-a1.md" ] || echo "PROBE: staged file deleted after clear"
    "$ST" read "$ISSUE" | jq -c '.pending_artifacts | map(.file)' | sed 's/^/PROBE: pending after clear /'
    ;;
  pending-blocked-role)
    printf 'report\n' > qa-report.md
    "$ST" stage-pending "$ISSUE" qa-report.md || die "stage failed"
    mkdir -p attempt1 && "$ST" copy-pending "$ISSUE" attempt1 || die "copy 1 failed"
    # the write role blocks / dies without pushing: nothing is cleared
    "$ST" read "$ISSUE" | jq -c '.pending_artifacts | length' | sed 's/^/PROBE: entries after a blocked attempt /'
    mkdir -p attempt2 && "$ST" copy-pending "$ISSUE" attempt2 || die "copy 2 failed"
    cmp -s attempt1/qa-report.md attempt2/qa-report.md && echo "PROBE: the next attempt re-lands the same file"
    ;;
  pending-tamper)
    printf 'honest content\n' > review-api-a1.md
    "$ST" stage-pending "$ISSUE" review-api-a1.md || die "stage failed"
    printf 'swapped content\n' > "$SWARM_FAKE_GH/state/pending-$ISSUE-review-api-a1.md"
    mkdir -p landing
    "$ST" copy-pending "$ISSUE" landing
    echo "PROBE: copy rc=$?"
    [ -f landing/review-api-a1.md ] || echo "PROBE: tampered file not copied"
    ;;
  create-twice)
    "$ST" apply null start --arg issue "$ISSUE" --arg repo "$REPO" --arg by owner --arg stage triage --arg role triage --arg swarm_sha 0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d > init.json || die "apply failed"
    "$ST" create "$ISSUE" init.json > /dev/null; echo "PROBE: create rc=$?"
    "$ST" create "$ISSUE" init.json | jq -r '.created_at' | sed 's/^/PROBE: existing created_at /'; echo "PROBE: create again rc=${PIPESTATUS[0]}"
    ;;
  billing)
    "$ST" billing-used owner | sed 's/^/PROBE: with token: /'
    echo "PROBE: rc=$?"
    SWARM_TOKEN='' "$ST" billing-used owner | sed 's/^/PROBE: without token: /'
    echo "PROBE: done"
    ;;
  next-key)
    "$ST" read "$ISSUE" > s.json || die "read failed"
    printf 'PROBE: %s %s %s\n' "$("$ST" next-key s.json build dev:app)" "$("$ST" next-key s.json build planner)" "$("$ST" next-key s.json test evidence)"
    ;;
  gate-flow)
    "$ST" write "$ISSUE" gate-enter --arg name architecture --arg from_key 7:architecture:threat-model:1 --arg comment_id 5 --arg done_stage architecture >/dev/null
    printf 'PROBE: gate rc=%s gate=%s\n' "$?" "$("$ST" read "$ISSUE" | jq -r .gate.name)"
    "$ST" write "$ISSUE" gate-approve --arg name requirements --arg by octo-owner --arg stage build --arg role planner >/dev/null
    echo "PROBE: approve-wrong-gate rc=$?"
    "$ST" write "$ISSUE" gate-approve --arg name architecture --arg by octo-owner --arg stage build --arg role planner > after.json
    printf 'PROBE: approve rc=%s status=%s next=%s wakeups=%s\n' "$?" "$(jq -r .status after.json)" "$(jq -r .next.key after.json)" "$(jq -r .totals.wakeups after.json)"
    ;;
  retro-done)
    "$ST" write "$ISSUE" stage-done --arg stage retro --arg from_key 7:retro:retro:1 >/dev/null || die "stage-done failed"
    "$ST" write "$ISSUE" "done" --arg from_key 7:retro:retro:1 --arg memory_pr 41 >/dev/null
    echo "PROBE: done rc=$?"
    ;;
  park-drop)
    "$ST" write "$ISSUE" park --arg by octo-owner > p.json
    printf 'PROBE: park rc=%s status=%s from=%s fired_at=%s\n' "$?" "$(jq -r .status p.json)" "$(jq -r .parked.from p.json)" "$(jq -r .next.fired_at p.json)"
    "$ST" write "$ISSUE" hands-off --arg by octo-owner > h.json
    printf 'PROBE: hands-off rc=%s flag=%s\n' "$?" "$(jq -r .flags.hands_off h.json)"
    "$ST" write "$ISSUE" drop --arg by octo-owner > d.json
    printf 'PROBE: drop rc=%s status=%s\n' "$?" "$(jq -r .status d.json)"
    "$ST" write "$ISSUE" drop --arg by octo-owner >/dev/null; echo "PROBE: drop again rc=$?"
    "$ST" write "$ISSUE" park --arg by octo-owner >/dev/null; echo "PROBE: park after drop rc=$?"
    ;;
  *) die "state-probe: unknown mode ${1:-}" ;;
esac
