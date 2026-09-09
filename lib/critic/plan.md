# Rubric: plan

Scores the planner's `plan.md` and `subissues[]`. Off by default — the plan is validated
mechanically (lanes ⊆ configured lanes, titles, body files); switch it on in
`pipeline.yml`. Threshold **60**. The critic reads `.swarm-run/brief.md`,
`.swarm-run/result.json`, the artifacts under `.swarm-run/artifacts/` and this file —
nothing else — and writes `.swarm-run/critic.json` with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `lanes` | 0.30 | the lane set is minimal: every lane in the plan has files in the touch set, and no touched file is outside every lane |
| `order` | 0.30 | the configured lane order is respected and every dependency between lanes names the file and symbol the later lane consumes |
| `tests` | 0.40 | every AC is owned by exactly one lane with a named expected test, and the done criteria are the lane's commands green plus its pins flipped |

### lanes (0.30)

- **40** — a lane with nothing to change, or a touched glob matching no lane, or an
  invented lane name.
- **70** — the lane set is right; one glob is broader than the touch set needs.
- **90** — every lane earns its place with named files; the size estimate fits the limits
  and shows its arithmetic.

### order (0.30)

- **40** — lanes reordered against the configuration, or a dependency stated with no
  file or symbol.
- **70** — order respected; one dependency is implied by the ADR but not written in the plan.
- **90** — every cross-lane contract is named by file and symbol, so the test-writer can
  pin it before the first lane starts.

### tests (0.40)

- **40** — an AC owned by two lanes or by none; "tests as appropriate" instead of names.
- **70** — every AC owned once with a named test; one spanning AC's ownership is not
  explained.
- **90** — every AC has a test name in the lane's layout, the invariant has its own test,
  and done criteria are mechanical (commands, pins, ACs walkable).

## Rules

- Cite `where` for every finding: `plan.md § Lane: api Files`, `plan.md § Size`,
  `result.json subissues[1].title`. A finding without a `where` does not exist.
- **A claim without a checkable path or command scores ≤ 40 on grounded** — in this
  rubric the grounded dimension is `lanes`: a size estimate with no file listing or
  command behind it caps it.
- Every area the artifact could not check must be stated in it as one sentence per area,
  verbatim in this form: `Not exercised: <area> — <reason>.` An artifact that implies
  coverage it does not have scores ≤ 40 on `lanes`; a missing sentence is a `medium`
  finding. What you could not check yourself is a `low` finding whose `claim` starts
  `Not exercised by the critic:` and lowers `confidence`.
- `score` = round(0.30·lanes + 0.30·order + 0.40·tests). `verdict` = `pass` iff
  `score ≥ 60` and no `high` finding. `high` = two devs would edit the same file, or an
  AC has no owner.
- `confidence`: `high` when every glob and file was checked against the tree; `medium`
  when some rested on plausibility; `low` when the touch set could not be read (`low` +
  `fail` goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "build", "target_key": "7:build:planner:1",
  "rubric": "plan", "model": "<model id from the prompt>",
  "score": 68, "threshold": 60,
  "dimensions": { "lanes": 70, "order": 60, "tests": 72 },
  "findings": [ { "severity": "medium", "where": "plan.md § Dependencies between lanes",
                  "claim": "the second lane consumes a DTO the first lane produces, unnamed",
                  "why": "adr.md § Touch set lists the mirrored type in both lanes; the plan does not say which side moves first",
                  "fix": "name the file and symbol and put the producing lane first" } ],
  "verdict": "pass", "confidence": "medium" }
```
