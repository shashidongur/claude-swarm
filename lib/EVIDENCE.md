# Evidence workflows — the contract for project authors

The swarm never waits on a runner. Evidence — CI on every push, an optional device
walkthrough before `qa`, an optional security scan before the `security` role — is
produced by the **project's own workflows**, fired by the dispatcher and consumed when
GitHub reports them complete. What was and was not exercised is a machine contract
(`manifest.json`), not the honesty of the role that reads it.

## What a project declares

In `.github/swarm.yml`:

```yaml
evidence:
  ci: CI                     # workflow `name:` that runs on pull_request; matched by head_sha
  test: walkthrough          # optional: fired before qa; must accept inputs issue, ref, key
  security: security         # optional: fired before the security role
walkthrough_when: ["<client lane>/**"]   # globs on touches; empty = always on the full path
```

The stub's `workflow_run.workflows` list must contain the same names, literally —
`resolve.sh` warns on the control issue when one is missing, because a `workflow_run`
for a workflow not in that list never reaches the dispatcher.

## The five points

An evidence workflow fired by the dispatcher must:

1. **Trigger on `workflow_dispatch` with inputs `issue`, `ref`, `key`** (strings) and set
   `run-name: "<name> swarm#${{ inputs.issue }} ${{ inputs.key }}"`. `resolve` maps the
   `workflow_run` back to the issue by `swarm#<N>` and to the exact wait by the key — a
   rework loop fires the same workflow twice for one issue, and the key disambiguates.
2. **Check out `inputs.ref` with `persist-credentials: false`** and declare top-level
   `permissions: { contents: read }` and **no `secrets.*` references**. The checked-out
   ref is branch-controlled code (lifecycle scripts, build tooling, the walkthrough
   script), and a write-capable default token in its environment would let a branch push
   to the default branch silently.
3. **Upload exactly one artifact named `<name>-<issue>-<short sha>`** (`retention-days:
   14`) containing machine-readable results, a `SUMMARY.md`, and a **`manifest.json`**:
   ```jsonc
   { "v": 2, "issue": 7, "ref": "<sha>", "key": "7:test:evidence:1", "produced_at": "…",
     "sections": { "unit": { "ran": true }, "e2e": { "ran": false, "reason": "emulator boot timeout" },
                   "visual": { "ran": false, "reason": "no baseline images" }, "coldstart": { "ran": true },
                   "dast": { "ran": false, "reason": "no OpenAPI spec at docs/openapi.yaml; DAST not run" } } }
   ```
   Every `reason` of a section with `ran: false` is copied verbatim by the consuming role
   into its `not_covered[]` — the validator refuses the report otherwise (V17).
4. **Fail the job when the evidence says fail** (a failing flow, a scanner finding, a
   non-zero exit) — the conclusion is the signal `advance` reads. An *environment*
   failure (an emulator that never booted, a registry that timed out) sets `ran: false`
   with a reason and does **not** fail the job: it is not the dev's rework.
5. **Live on the default branch** (`workflow_run` fires only for default-branch workflow
   files) and be listed in the stub's `workflow_run.workflows`.

The stub itself obeys a stricter version of point 5: the write-class jobs
(test-writer, dev, release and their critic) mint the Claude App token through an OIDC
exchange that refuses a calling workflow file which is not identical on the default
branch ("Workflow validation failed"), so the stub must be merged to the default branch
before the first write-class role runs; read-class roles run from any branch. What the
App token can reach (R28) and whether it can merge a PR or push a workflow file (R29)
are measured at switch-on, with the stub on the default branch.

`templates/evidence-workflow.md` is a minimal generic example.

## How the dispatcher fires and consumes it

`gh workflow run <file> --ref <default_branch> -f issue=<N> -f ref=<head> -f key=<key>`
under `github.token` (`actions: write`), then verified by the key in `displayTitle`
(the same claim-and-verify loop as a stage fire; failure → `blocked:fire`). It records
`evidence.pending.run_id`, increments `evidence.fires[<workflow>]`, sets `status =
evidence` and the label `swarm:waiting:evidence`, and stops. The workflow's
`workflow_run: completed` event fires the stub; `resolve` records the conclusion under
`evidence.seen[head][workflow][event]` — **at any status**, because CI routinely
finishes while the write role is still running — and, when it matches the pending wait,
fires the consumer.

Before waiting, `advance` consults `seen`, then asks GitHub
(`actions/runs?head_sha=<head>&event=pull_request`): a completed run is consumed at once,
an in-flight one has its `run_id` recorded. The watchdog and `/swarm resume` repeat the
query; after `evidence_timeout_minutes` (120) with no completion the issue is
`blocked:evidence`.

Downloads land under `.swarm-run/evidence/<workflow>/` for the consuming role, with
`evidence/index.json` naming each run, its conclusion and whether the artifact was
found. A missing artifact gets a synthetic `manifest.json` with every section
`{ran: false, reason: "artifact missing"}`, so the role has to say so.

## The fire cap, and the other two reasons a fire is skipped

- **`evidence_fires_per_issue` (2) per workflow per issue.** A rework loop would
  otherwise re-run the emulator on every new head. Past the cap the stage runs on CI
  evidence alone with a synthetic manifest whose every section reads
  `evidence fire cap reached (N); CI evidence only` — the role must repeat it, and the
  release critic sees it.
- **The monthly brake** (`runner_minutes_month`, `usd_month`): skipped with the reason
  `monthly budget`, and the stage comment says so.
- **The perimeter**: an evidence workflow is never fired on a branch whose diff touches
  `.github/**` — the branch would be running its own workflow file.

Evidence fires are keyed on `(workflow, head)`: a head that already has a conclusion for
that workflow is not re-fired.

## CI is evidence too

The project's CI on `pull_request` is recorded per `(head, workflow, event)` like any
other evidence and gates three things: `code-review` is not fired while CI on the head
is red (the failing job's log tail goes back to `dev:<lane>` as the repro), and `qa` and
`security` cannot return `pass` while the CI conclusion on `state.head` is not
`success`. "Red" means typecheck, lint, tests outside the project's baselines, coverage
below threshold, a secret, or a **new** audit/SAST finding — never a finding that
already exists on the default branch. A scanner that is red on `main` must not send
every dev into rework it cannot fix; that is why the project baselines its audit and
SAST output and never its secret scan.

CI should run **once per push**: trigger on `pull_request` (and `push` to the default
branch only), with `concurrency: { group: CI-${{ github.head_ref || github.ref_name }},
cancel-in-progress: true }` so a newer push cancels the older PR run (a cancelled run is
recorded and ignored). A `push` trigger on the swarm's branches as well would run every
head twice in two concurrency groups and emit two `workflow_run` events with possibly
different conclusions.

## The token rule

**The PR is opened and every push is made by a role under the App token; the
dispatcher never pushes to a branch with an open PR.** A push made with `github.token`
fires no `pull_request: synchronize` run that CI would honour — GitHub creates it in an
"approval required" state — so it would move the branch head to a commit whose CI
evidence never arrives, and muddle the PR's check state. Before a PR exists the
dispatcher may commit read-role artifacts to the branch (documents; nothing needs CI
on them); after it exists, dispatcher artifacts are staged on `swarm/state` and land
with the next role's own push. The same fact is why the test-writer — not a workflow
step — opens the draft PR at its first push: `pull_request: opened` by the App token
runs CI on that sha within seconds.

Project workflows, for their part, never hold a write token (point 2), and the
repository's *Actions → Workflow permissions* setting is read-only, so a forgotten
`permissions:` block cannot restore write.
