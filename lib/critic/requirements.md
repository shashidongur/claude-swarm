# Rubric: requirements

Scores the analyst's `requirements.md` before gate 1 (full path only). Threshold **70**.
The critic reads `.swarm-run/brief.md`, `.swarm-run/result.json`, the artifacts under
`.swarm-run/artifacts/` and this file — nothing else — and writes `.swarm-run/critic.json`
with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `grounded` | 0.30 | every story and AC traces to the fenced issue text or to a requirement id that grep-hits the project's requirements document |
| `complete` | 0.30 | every user-visible behaviour the issue asks for has an AC, including the failure, empty and permission paths it implies |
| `testable` | 0.30 | each AC is one yes/no observation in Given/When/Then, naming the role who observes it |
| `scoped` | 0.10 | nothing invented: no behaviour the issue did not ask for, no decision `decisions.md` already settled reopened |

### grounded (0.30)

- **40** — stories restate the issue title; `refs[]` is empty or lists ids that do not
  grep-hit; at least one AC rests on a rule that appears nowhere in the inputs.
- **70** — every AC cites the issue sentence or requirement id it comes from; one or two
  ACs lean on an assumption, and that assumption is listed under Assumptions.
- **90** — every AC cites its source by id or quoted sentence; every assumption names what
  would change if it were wrong; nothing rests on the analyst's memory of similar products.

### complete (0.30)

- **40** — the happy path only; an error, empty or permission case the issue implies has
  no AC.
- **70** — every behaviour in the issue has an AC; one implied edge (the second tap, the
  lapsed user) is missing or folded into another AC.
- **90** — every behaviour and every implied edge has its own AC; out-of-scope items are
  named so their absence is deliberate.

### testable (0.30)

- **40** — ACs are adjectives ("improved", "faster", "clear") or bundle several
  observations in one sentence; no role is named.
- **70** — every AC is Given/When/Then with a role; one or two "Then" clauses need
  interpretation before they become an assertion.
- **90** — every "Then" is a single assertion a test-writer can name a fixture for; the
  role and the starting state are explicit in every Given.

### scoped (0.10)

- **40** — ACs add behaviour the issue did not ask for, or reopen a recorded decision.
- **70** — scope matches the issue; the out-of-scope section is thin.
- **90** — scope matches; exclusions are explicit; recorded decisions are cited, not restated.

## Rules

- Cite `where` for every finding: `requirements.md AC-7-5`, `requirements.md § Out of
  scope`, `result.json refs[1]`. A finding without a `where` does not exist.
- **A claim without a checkable path or command scores ≤ 40 on `grounded`.** A requirement
  id you cannot grep, a screen the tree does not contain, an "the app already does X"
  with no `path:line` — each caps the dimension.
- Every area the artifact could not check must be stated in it as one sentence per area,
  verbatim in this form: `Not exercised: <area> — <reason>.` (for this stage typically
  `Not exercised: the running application — read-only stage; ACs were written from the
  screen source.`). An artifact that implies coverage it does not have scores ≤ 40 on
  `grounded`; a missing sentence is a `medium` finding on `complete`. What you could not
  check yourself is a `low` finding whose `claim` starts `Not exercised by the critic:`
  and lowers `confidence`.
- `score` = round(0.30·grounded + 0.30·complete + 0.30·testable + 0.10·scoped). `verdict`
  = `pass` iff `score ≥ 70` and no `high` finding. `high` = the owner would approve
  something false at the gate.
- `confidence`: `high` when every claim was checkable and checked; `medium` when some
  rested on plausibility; `low` when the central claim could not be checked (`low` +
  `fail` goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "requirements", "target_key": "7:requirements:analyst:1",
  "rubric": "requirements", "model": "<model id from the prompt>",
  "score": 84, "threshold": 70,
  "dimensions": { "grounded": 90, "complete": 80, "testable": 85, "scoped": 75 },
  "findings": [ { "severity": "medium", "where": "requirements.md AC-7-5",
                  "claim": "the capacity limit is asserted without a requirement id",
                  "why": "no id in refs[] grep-hits a capacity rule",
                  "fix": "cite the requirement or move the rule to Assumptions" } ],
  "verdict": "pass", "confidence": "high" }
```
