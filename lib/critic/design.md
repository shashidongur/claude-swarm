# Rubric: design

Scores the ux role's `design.md`. Off by default — the a11y role is the paired checker;
switch it on in `pipeline.yml`. Threshold **65**. The critic reads `.swarm-run/brief.md`,
`.swarm-run/result.json`, the artifacts under `.swarm-run/artifacts/` and this file —
nothing else — and writes `.swarm-run/critic.json` with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `states` | 0.40 | the states table has every required row (initial, loading, empty, error, offline, partial, after-first-action) and one row per AC with a visible surface, each with a trigger and a cited primitive |
| `copy` | 0.30 | every string the user sees is written out verbatim, including the error and empty states, with its slot named |
| `a11y` | 0.30 | the accessibility intent is stated for every new control: target size, screen-reader label, behaviour at the largest font size, longest realistic string, contrast against its token |

### states (0.40)

- **40** — a required row is missing, or a row's primitive cell has no `path:line`; an AC
  with a visible surface has no row.
- **70** — every required row exists and cites a primitive; one AC row is folded into
  another; one trigger is vague ("when it fails").
- **90** — every row has a precise trigger, exact copy and a cited primitive; ACs with no
  visible surface have a row saying so.

### copy (0.30)

- **40** — placeholders ("error message here"), or copy that describes instead of quotes.
- **70** — every state has its copy; one string exceeds its slot at the longest length
  and the table does not say what happens.
- **90** — every string is verbatim, its slot named, truncation and wrapping behaviour
  stated for the longest realistic value.

### a11y (0.30)

- **40** — no intent section, or a new control with no label.
- **70** — every control has a label and a target size; font scaling or contrast is
  unstated for one component.
- **90** — every item stated per control and cited against the component's existing
  behaviour where it already exists in the tree.

## Rules

- Cite `where` for every finding: `design.md § States row empty`, `design.md § Copy
  "Retry"`, `design.md § Accessibility intent`. A finding without a `where` does not exist.
- **A claim without a checkable path or command scores ≤ 40 on grounded** — in this
  rubric the grounded dimension is `states`: a primitive or token with no `path:line`
  where it is already used is an invented value.
- Every area the artifact could not check must be stated in it as one sentence per area,
  verbatim in this form: `Not exercised: <area> — <reason>.` (typically the running
  application, or a platform the design system does not render in this project). An
  artifact that implies coverage it does not have scores ≤ 40 on `states`; a missing
  sentence is a `medium` finding. What you could not check yourself is a `low` finding
  whose `claim` starts `Not exercised by the critic:` and lowers `confidence`.
- `score` = round(0.40·states + 0.30·copy + 0.30·a11y). `verdict` = `pass` iff
  `score ≥ 65` and no `high` finding. `high` = a user on the error or empty path would
  see nothing, or a control has no accessible name.
- `confidence`: `high` when every cited primitive was opened; `medium` when some rested
  on plausibility; `low` when the design system could not be located (`low` + `fail`
  goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "design", "target_key": "7:design:ux:1",
  "rubric": "design", "model": "<model id from the prompt>",
  "score": 72, "threshold": 65,
  "dimensions": { "states": 75, "copy": 70, "a11y": 70 },
  "findings": [ { "severity": "medium", "where": "design.md § States row offline",
                  "claim": "the offline row has no copy",
                  "why": "the cell says 'show cached data' without the banner text the user reads",
                  "fix": "write the banner string and name its slot" } ],
  "verdict": "pass", "confidence": "high" }
```
