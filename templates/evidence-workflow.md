# Writing an evidence workflow

The dispatcher fires a project's evidence workflows (`evidence.test` before `qa`,
`evidence.security` before the `security` role) and consumes them when GitHub reports
them complete. The contract is five points (`lib/EVIDENCE.md`); this is the smallest
workflow that meets all five.

## The five points, checked against the example below

1. `workflow_dispatch` with string inputs `issue`, `ref`, `key`; `run-name` ends with
   `swarm#<issue> <key>` so the run can be found by the key.
2. Checks out `inputs.ref` with `persist-credentials: false`; top-level `permissions:
   { contents: read }`; **no `secrets.*` anywhere** — the ref is branch-controlled code.
3. Uploads exactly one artifact `<name>-<issue>-<short sha>` (14 days) with
   machine-readable results, `SUMMARY.md` and `manifest.json` whose every section says
   `ran: true` or `ran: false` with a `reason`.
4. Fails the job when the evidence says fail; an environment failure sets `ran: false`
   with a reason and does not fail the job (`continue-on-error` on the environment step,
   the result read from its outcome).
5. Lives on the default branch and is named in the stub's `workflow_run.workflows`.

## Minimal example

```yaml
name: walkthrough                                  # must equal `evidence.test` in .github/swarm.yml
run-name: "walkthrough swarm#${{ inputs.issue }} ${{ inputs.key }}"

on:
  workflow_dispatch:
    inputs:
      issue: { type: string, required: true }
      ref:   { type: string, required: true }       # the head sha the dispatcher wants exercised
      key:   { type: string, required: true }       # e.g. 7:test:evidence:1 — copied into the manifest

permissions:
  contents: read                                   # nothing here may write; no secrets.* below

jobs:
  run:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ inputs.ref }}
          persist-credentials: false

      - id: setup                                  # environment: allowed to fail without failing the job
        continue-on-error: true
        run: ./scripts/boot-device.sh              # whatever brings the environment up

      - id: flows                                  # evidence: its exit code is the signal
        if: steps.setup.outcome == 'success'
        continue-on-error: true
        run: ./scripts/run-flows.sh --junit out/junit.xml --screenshots out/shots

      - name: manifest
        if: always()
        env:
          ISSUE: ${{ inputs.issue }}
          KEY: ${{ inputs.key }}
          REF: ${{ inputs.ref }}
          SETUP: ${{ steps.setup.outcome }}
          FLOWS: ${{ steps.flows.outcome }}
        run: |
          mkdir -p out
          if [ "$SETUP" = "success" ]; then
            E2E='{"ran": true}'
          else
            E2E='{"ran": false, "reason": "emulator boot timeout"}'   # copied verbatim into not_covered[] by qa
          fi
          jq -n --arg issue "$ISSUE" --arg key "$KEY" --arg ref "$REF" --argjson e2e "$E2E" \
            '{v: 2, issue: ($issue | tonumber), ref: $ref, key: $key, produced_at: (now | todate),
              sections: { e2e: $e2e, visual: {ran: false, reason: "no baseline images"} }}' > out/manifest.json
          {
            echo "# walkthrough swarm#$ISSUE"
            echo "ref: $REF · key: $KEY · setup: $SETUP · flows: $FLOWS"
            echo "Not exercised: whatever manifest.json says ran=false, with its reason."
          } > out/SUMMARY.md

      - name: upload
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: walkthrough-${{ inputs.issue }}-${{ inputs.ref }}
          path: out
          retention-days: 14

      - name: verdict                              # fail only on evidence, never on environment
        if: always() && steps.flows.outcome == 'failure'
        run: |
          echo "::error::flows failed — see the artifact"
          exit 1
```

Adapt the two scripts, the section names and the reasons; keep everything else. The
artifact name may use a short sha — the dispatcher matches on the run, not the name —
but it must be the only artifact the run uploads.

## What the consuming role sees

`begin.sh` downloads the artifact into `.swarm-run/evidence/<workflow>/` and writes
`evidence/index.json` with the run id, conclusion and URL. Every `reason` of a section
with `ran: false` must appear verbatim in the role's `not_covered[]` (validator check
V17); a missing artifact is reported as `artifact missing` in a synthetic manifest so
the role has to say so. Beyond `evidence_fires_per_issue` (2) fires per workflow per
issue, the dispatcher does not fire the workflow again and the stage runs on CI evidence
with the reason `evidence fire cap reached (N); CI evidence only`.

## If `workflow_run` does not reach the stub

`workflow_run` fires only for workflow files on the default branch, and only for the
names listed in the stub's `workflow_run.workflows`. If a run completes and the issue
stays at `swarm:waiting:evidence`, check those two things first; the watchdog and
`/swarm resume` re-query GitHub for the run by head sha, and after
`evidence_timeout_minutes` (120) the issue is `blocked:evidence` rather than stuck.
As a last resort an evidence workflow may add a final job that fires the stub itself —
`gh workflow run swarm-dispatch.yml -R <owner/repo> -f issue=<N> -f reason=evidence
-f key=<key>` under `github.token` with `actions: write` on that job only — but that
job must not check out the ref, or point 2 no longer holds.
