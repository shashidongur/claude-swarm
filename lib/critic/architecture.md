# Rubric: architecture

Scores the architect's five artifacts together with the threat-model's report, after the
threat-model role and before gate 2 (full path only). Threshold **70**. The critic reads
`.swarm-run/brief.md`, `.swarm-run/result.json`, the artifacts under
`.swarm-run/artifacts/` and this file — nothing else — and writes `.swarm-run/critic.json`
with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `reuse` | 0.30 | the frozen shape reuses what the tree already has, cited `path:line`; every predicate and every hand-mirrored copy is named |
| `migration` | 0.25 | the storage change is reversible and idempotent, with backfill and backward steps, or is a deliberate `none` |
| `contract` | 0.25 | `openapi.yaml` and the ADR cover every AC: every field an AC observes has a place in the contract |
| `threats` | 0.20 | every gap the threat-model found is addressed in the design or explicitly deferred with an owner |

### reuse (0.30)

- **40** — a new type where one exists; a predicate frozen as a method body with no grep
  for existing occurrences; mirrored copies unmentioned.
- **70** — the existing shape is cited; the predicate grep was done; one carrier file or
  call site is missing from the touch set.
- **90** — every existing occurrence and every carrier file is listed with `path:line`;
  what does not change is stated; no invented plan or index claim.

### migration (0.25)

- **40** — a forward step only; a statement that fails on re-run; a backfill with no size
  or verification; `none` with no reason.
- **70** — forward and backward steps present; idempotency asserted for each statement;
  the backfill's verification is thin.
- **90** — each statement is individually re-runnable per the project's discipline; the
  backfill has a size, a duration and a check; the backward step is tested in words.

### contract (0.25)

- **40** — `openapi.yaml` does not parse, or an AC observes a field that appears in no
  schema; error responses are absent.
- **70** — every AC maps to an endpoint and field; one error path or edge state from
  `design.md` has no response defined.
- **90** — every AC, every design state and every error path has a schema; the invariant
  is one sentence and the contract cannot express a value that violates it.

### threats (0.20)

- **40** — the threat-model's gaps are not mentioned, or "mitigated" without a citation.
- **70** — every gap is addressed or deferred; one deferral has no owner.
- **90** — every gap is addressed in the ADR with the mitigation's `path:line` or deferred
  with an owner and a reason; the data-handling table has no blank cell.

## Rules

- Cite `where` for every finding: `adr.md § Decision`, `openapi.yaml paths./sessions`,
  `migration-plan.md step 3`, `threat-model.md row 4`. A finding without a `where` does
  not exist.
- **A claim without a checkable path or command scores ≤ 40 on grounded** — in this
  rubric the grounded dimension is `reuse`: an index, a query plan or an "already exists"
  with no `path:line` caps it.
- Every area the artifacts could not check must be stated in them as one sentence per
  area, verbatim in this form: `Not exercised: <area> — <reason>.` An artifact that
  implies coverage it does not have scores ≤ 40 on `reuse`; a missing sentence is a
  `medium` finding on `threats`. What you could not check yourself is a `low` finding
  whose `claim` starts `Not exercised by the critic:` and lowers `confidence`.
- `score` = round(0.30·reuse + 0.25·migration + 0.25·contract + 0.20·threats). `verdict`
  = `pass` iff `score ≥ 70` and no `high` finding. `high` = a dev building this would
  produce two disagreeing sides of a boundary, or an irreversible storage change.
- `confidence`: `high` when every claim was checkable and checked; `medium` when some
  rested on plausibility; `low` when the central claim could not be checked (`low` +
  `fail` goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "architecture", "target_key": "7:architecture:threat-model:1",
  "rubric": "architecture", "model": "<model id from the prompt>",
  "score": 79, "threshold": 70,
  "dimensions": { "reuse": 85, "migration": 70, "contract": 80, "threats": 80 },
  "findings": [ { "severity": "medium", "where": "migration-plan.md step 2",
                  "claim": "the backfill has no verification step",
                  "why": "a partial backfill would leave rows with a null the contract forbids",
                  "fix": "add a count query before and after, and the expected difference" } ],
  "verdict": "pass", "confidence": "high" }
```
