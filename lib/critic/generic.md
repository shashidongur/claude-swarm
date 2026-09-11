# Rubric: generic

Scores any artifact for which no specific rubric exists. Threshold **65**. The critic
reads `.swarm-run/brief.md`, `.swarm-run/result.json`, the artifacts under
`.swarm-run/artifacts/` and this file — nothing else — and writes `.swarm-run/critic.json`
with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `grounded` | 0.40 | every claim in the artifact and in `result.json` points at something checkable: a `path:line`, a command with its output, an evidence file, an id that greps |
| `complete` | 0.30 | the artifact has every section its role file requires and answers what the brief asked, including the edges the brief's inputs imply |
| `honest` | 0.30 | what was not done, not checked or not reachable is said plainly, in the fixed form, rather than implied covered |

### grounded (0.40)

- **40** — a claim with nothing behind it; an evidence item whose path does not exist or
  whose symbol is not near the line; a number that matches no source.
- **70** — every claim cites something; one citation is stale or points at a summary.
- **90** — every claim opens to its source at the head; the reader could re-derive the
  verdict from the citations alone.

### complete (0.30)

- **40** — a required section missing or empty; the brief's question answered partially.
- **70** — every section present; one implied edge unaddressed.
- **90** — every section present and specific; the edges the inputs imply are handled or
  named as out of scope.

### honest (0.30)

- **40** — coverage implied that the evidence does not support; a limitation buried or
  absent.
- **70** — limitations stated; one is vague about why.
- **90** — every limitation stated in the fixed form with its reason, where the next
  reader will look.

## Rules

- Cite `where` for every finding: `<artifact> § <section>`, `result.json evidence[2]`. A
  finding without a `where` does not exist.
- **A claim without a checkable path or command scores ≤ 40 on `grounded`.**
- Every area the artifact could not check must be stated in it as one sentence per area,
  verbatim in this form: `Not exercised: <area> — <reason>.` An artifact that implies
  coverage it does not have scores ≤ 40 on `honest`; a missing sentence is a `medium`
  finding. What you could not check yourself is a `low` finding whose `claim` starts
  `Not exercised by the critic:` and lowers `confidence`.
- `score` = round(0.40·grounded + 0.30·complete + 0.30·honest). `verdict` = `pass` iff
  `score ≥ 65` and no `high` finding. `high` = a later stage or a human would act on
  something false.
- `confidence`: `high` when every claim was checkable and checked; `medium` when some
  rested on plausibility; `low` when the central claim could not be checked (`low` +
  `fail` goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "build", "target_key": "7:build:planner:1",
  "rubric": "generic", "model": "<model id from the prompt>",
  "score": 71, "threshold": 65,
  "dimensions": { "grounded": 75, "complete": 70, "honest": 65 },
  "findings": [ { "severity": "low", "where": "plan.md § Size",
                  "claim": "Not exercised by the critic: the size estimate — no file listing was cited to check it against",
                  "why": "the section gives a line count with no command behind it",
                  "fix": "add the listing command and its count" } ],
  "verdict": "pass", "confidence": "medium" }
```
