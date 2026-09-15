# Routing — data, not prose

Routing is data: `pipeline.yml` is the source, `pipeline.json` is generated from it, and
the dispatcher reads only the JSON. Nothing a role writes carries the baton. A role
writes `.swarm-run/result.json` and its artifacts; `advance` reads the verdict, looks up
the edge in `pipeline.json`, writes the next key into the signed state, **claims the
fire**, and runs `gh workflow run` on the project's stub. The mention grammar of v1 is
gone, and with it the whole class of stalls where a malformed line meant no next run.

## The stage table

Rendered from `pipeline.json` by `lib/conformance/render-routing.sh` and diffed in CI
against the block below, so this table can never drift from what the dispatcher runs.
To change routing, change `pipeline.yml`, regenerate `pipeline.json`, re-render this
block; do not edit the table by hand.

Columns: `#`, `Stage / label`, `Roles in order` (`role:<lane>` = one run per lane in
the project's configured lane order; `evidence <workflow> →` = an evidence workflow is
fired before the stage's first role), `Tier` and `Class` per role, `Artifacts` the roles
must produce under `.swarm-run/artifacts/`, `Critic / check` (the critic slot with its
rubric and threshold, `(off)` when present but disabled, and the mechanical
preconditions `requires_ci` / `requires_evidence` / `requires_scan`), `Rework edges`
(`role rework → target ×max`, `CI red after role → target`, `critic → target`, and the
owner's free reject edge), `Gate after`, and `Short path` (the stage's `on_short` plus
the per-role, evidence and critic exceptions).

<!-- routing-table -->
| # | Stage / label | Roles in order | Tier | Class | Artifacts | Critic / check | Rework edges | Gate after | Short path |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `triage` / `swarm:triage` | `triage` | cheap | read | `triage.json` | — | — | none | runs |
| 2 | `requirements` / `swarm:requirements` | `analyst` | default | read | `requirements.md` | critic `requirements` ≥ 70 (full only) | owner reject → `analyst` (free) | `requirements` (full only) | runs; no gate; no critic |
| 3 | `design` / `swarm:design` | `ux` → `a11y` | default, default | read, read | `design.md`, `a11y.md` | critic `design` ≥ 65 (off) (full only) | `a11y` rework → `ux` ×1 | none | **skipped** |
| 4 | `architecture` / `swarm:architecture` | `architect` → `threat-model` | strong, default | read, read | `adr.md`, `openapi.yaml`, `migration-plan.md`, `flags.md`, `rollback.md`, `threat-model.md` | critic `architecture` ≥ 70 (full only) | `threat-model` rework → `architect` ×1; critic → `architect`; owner reject → `architect` (free) | `architecture` (full only) | **skipped** |
| 5 | `build` / `swarm:build` | `planner` → `test-writer` → `dev:<lane>` → `code-review:<lane>` | default, default, default, strong | read, write, write, read | `plan.md`, sub-issues, `test-plan.md`, `pr-body.md`, draft PR, `review-<lane>-a<attempt>.md` | critic `plan` ≥ 60 (off); check: CI success before `code-review:<lane>` | CI red after `dev:<lane>` → `dev:<lane>`; `code-review:<lane>` rework → `dev:<lane>` | none | runs; `planner` skipped |
| 6 | `test` / `swarm:test` | evidence `test` → `qa` | default | read | `qa-report.md` | critic `report` ≥ 65 (off); check: CI success before `qa`; check: evidence success for `qa` | `qa` rework → `dev:<lane>` | none | runs; no `test` evidence |
| 7 | `security` / `swarm:security` | evidence `security` → `security` → `compliance` | default, strong | read, read | `security-report.md`, `compliance.md` | check: scan success for `security` | `security` rework → `dev:<lane>`; `compliance` rework → `dev:<lane>` | none | runs; `security` when_scan_changed; `compliance` sensitive_only; no `security` evidence |
| 8 | `release` / `swarm:release` | `release` | default | write | `release.md`, `pr-body.md` | critic `release` ≥ 70, separate job | owner reject → `analyst-feedback` (free) | `release` = merge by an approver | runs |
| 9 | `retro` / `swarm:retro` | `retro` | default | read | `postmortem.md` | — | — | none | runs |
<!-- /routing-table -->

Tiers: `cheap` = `claude-haiku-4-5`, `default` = `claude-sonnet-5`, `strong` =
`claude-opus-5` (`pipeline.yml models.tiers`). A critic runs on the *other* tier from
the role it scores (`critic_tier_for`), and `must_differ_from` is conformance-checked —
`code-review` is strong precisely because `dev` is default: reviewer ≠ author by model,
not only by instance. Lane names are the project's (`.github/swarm.yml lanes`, in the
order written there); the swarm never names them.

## What a verdict does

`pipeline.yml verdict_edges` is the whole rule, per role:

| Verdict | Edge |
|---|---|
| `pass` | the next role in the stage; then the stage's `evidence_after` wait (CI on the pushed head), then the stage's gate, then the next stage on the path (firing its `evidence_before` workflow first when configured) |
| `rework` | the role's `rework_to` target at attempt+1 — fixed in `pipeline.yml` for `a11y` (→ `ux`), `threat-model` (→ `architect`) and `code-review` (→ `dev:<lane>`); named by the role in `result.rework_to` for `qa`, `security`, `compliance` (must be a lane of this issue) |
| `blocked` | `swarm:blocked` + `blocked:role-stopped`; a `reason` starting `injection:` is `blocked:injection` instead. Distinct from `blocked:agent-output`, which means no valid result came back at all |
| `question` | analyst only: `swarm:gate:question`, the questions posted to the issue author; their next plain comment resumes the analyst |
| `duplicate` | triage only: `swarm:parked` + `blocked:duplicate`, the duplicates named in a comment |

A critic's `fail` is not a verdict of the role; it is handled by `advance` (§ Critics
in `lib/AUDIT.md`): one automatic rework at attempt+1 carrying only the findings, then
`swarm:gate:confidence`.

## Rework, and where the budget lives

Every backward edge — `code-review`, `qa`, `security`, `compliance`, `a11y`,
`threat-model`, a critic rework, a CI-red rework — shares **one budget of five per
issue**, stored as `rework.spent` in the state file (never derived from comments; v1
counted its own noise). Spent ≥ budget when about to fire a rework edge →
`swarm:blocked` + `blocked:budget`.

The owner's own `/swarm reject <why>` and `/swarm redo <stage>` are **free and reset
the counter** — without the reset, late feedback would block almost immediately, and the
owner's own comment would be the thing that stopped the work.

## Gates

Three, and they are comments or a merge, never a job that waits (`lib/GATES.md`):

| After | Label | Approve with |
|---|---|---|
| `requirements` (full path only) | `swarm:gate:requirements` | `/swarm approve` |
| `architecture` (full path only) | `swarm:gate:architecture` | `/swarm approve` |
| `release` (both paths) | `swarm:gate:release` | **an approver merges the PR** |

Three wait-states look like gates and are resumed the same way: `question` (the analyst
needs the reporter), `confidence` (a critic failed twice), `budget` (the per-issue cost
cap was reached; `/swarm approve` raises it by one envelope).

## The short path

`triage` chooses it, and only when `size:S` ∧ `type ∈ {bug, chore}` ∧ one lane
(validator check V15 downgrades anything else to `full` and records it). Short skips
`design`, `architecture`, the `planner`, gates 1 and 2, every critic but `release`'s,
the `test` and `security` evidence workflows; the `security` role runs only when CI's
audit/SAST counts differ from the baselines, and `compliance` only when the touches
intersect `sensitive_paths`. The analyst may escalate (`hints.path: full`); the owner
may override either way with `/swarm path full|short` while the stage is still
`requirements` or earlier.

## Four rules that keep the graph safe

1. **A role never routes.** No mention, no label, no marker, no `next`: `result.json` has
   no field for it, and a `summary` that tries to smuggle one is sanitised at render
   time. The only thing a role decides is its verdict, and the edge for that verdict is
   data the role cannot edit (`pipeline.json` reaches the run job as an artifact and
   `advance` re-reads it from a fresh checkout).
2. **An unknown stage, role or edge is refused, never guessed.** A `dispatch_role` not in
   `pipeline.json`, a `rework_to` outside the issue's lanes, a `/swarm redo` naming a
   stage off the path → `blocked:bad-handoff`. A typo stalls the work visibly, not
   somewhere plausible.
3. **One dispatch per `(key, run_id)`.** The idempotency key is
   `<issue>:<stage>:<role>[:<lane>]:<attempt>`; the attempt is a monotonic counter in
   state, never a count of past records. A run that never claimed its key touches
   nothing; a finished `(key, run_id)` re-run is a no-op; a key that reappears is a
   distinct error.
4. **The fire is claimed before it happens.** `next-firing` is CAS-written into the
   signed state *before* `gh workflow run`, then the run is verified by the key at the
   end of the stub's `run-name`. Two writers (advance and a watchdog tick, `start`
   racing itself, `/swarm resume` typed during queue lag) can never both fire; a fire
   with no verified run is `blocked:fire` and a red job, never a log line.

## Starting and ending

**Starting.** An approver adds `swarm:ready` or comments `/swarm start [full|short]`.
The dispatcher creates the state file and the state comment, removes `swarm:ready`, and
fires `triage` (or `requirements` when a path is forced). A hand-added `swarm:triage`
gets one reply explaining this; it never starts anything.

**Ending.** `release` readies the PR; an approver merges it; the merge fires `retro`
exactly once, which proposes memory as a pull request on this repository and ends the
issue at `swarm:done`. There is no automatic path past the merge, and the merge counts
only when an approver made it (`lib/GATES.md`, gate 3).
