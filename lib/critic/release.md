# Rubric: release

Scores the release role's `pr-body.md` and `release.md` in a separate read-only job,
with the project checked out at the pushed head (both paths). Threshold **70**. The
critic reads `.swarm-run/brief.md`, `.swarm-run/result.json`, the artifacts under
`.swarm-run/artifacts/` and this file — nothing else — and writes `.swarm-run/critic.json`
with the `Write` tool. This is the last screen before a human merges.

## Dimensions

| key | weight | definition |
|---|---|---|
| `claims` | 0.40 | every sentence in the body has an artifact, a `path:line` at the head, or a run URL under the repository behind it |
| `acs` | 0.30 | every AC is walked against the head sha: the test that pins it and the line where the behaviour lives, or an honest "not covered" |
| `not_covered` | 0.20 | the not-covered list carries every evidence manifest reason verbatim, every evidence-cap or budget skip, and every `Not exercised: …` sentence from qa, security and compliance |
| `readable` | 0.10 | a reader who has not seen the issue understands what changed and why in two minutes |

### claims (0.40)

- **40** — a claim with nothing checkable behind it ("fully tested", "no security
  impact"); an evidence link outside the repository; a number that matches no artifact.
- **70** — every claim cites something; one citation is stale (a line that moved after
  the last review).
- **90** — every claim opens to the thing it cites at this head; the numbers match
  `qa-report.md` and `security-report.md` exactly.

### acs (0.30)

- **40** — an AC is missing from the walk, or one qa listed as not covered is written as
  covered.
- **70** — every AC is walked with its test; one `path:line` points at the right file but
  the wrong line at this head.
- **90** — every AC has its test name and a `path:line` that resolves at the head;
  not-covered ACs are carried through with qa's wording.

### not_covered (0.20)

- **40** — a manifest reason is missing or paraphrased; an evidence-cap skip is not
  mentioned; a platform the runners cannot reach is implied covered.
- **70** — every manifest reason is present verbatim; one `Not exercised: …` sentence
  from a report is dropped.
- **90** — every reason, skip and sentence is present, grouped so the merger sees at a
  glance what a human still has to try.

### readable (0.10)

- **40** — a wall of logs, or a summary that restates the issue title.
- **70** — clear sections; the summary needs the issue for context.
- **90** — summary, what changed, ACs, evidence, not covered, rollback — each scannable;
  the rollback names the flag's kill path.

## Rules

- Cite `where` for every finding: `pr-body.md § Acceptance criteria AC-7-3`,
  `release.md § Numbers`, `pr-body.md § Evidence link 2`. A finding without a `where`
  does not exist.
- **A claim without a checkable path or command scores ≤ 40 on grounded** — in this
  rubric the grounded dimension is `claims`.
- Every area the evidence did not exercise must be stated in the body as one sentence per
  area, verbatim in this form: `Not exercised: <area> — <reason>.` A body that implies
  coverage it does not have scores ≤ 40 on `not_covered` and is a `high` finding — the
  merger must never be told something was checked when it was not. What you could not
  check yourself is a `low` finding whose `claim` starts `Not exercised by the critic:`
  and lowers `confidence`.
- `score` = round(0.40·claims + 0.30·acs + 0.20·not_covered + 0.10·readable). `verdict`
  = `pass` iff `score ≥ 70` and no `high` finding.
- `confidence`: `high` when every claim was opened at the head; `medium` when some rested
  on plausibility; `low` when the head or the artifacts could not be read (`low` + `fail`
  goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "release", "target_key": "7:release:release:1",
  "rubric": "release", "model": "<model id from the prompt>",
  "score": 78, "threshold": 70,
  "dimensions": { "claims": 80, "acs": 80, "not_covered": 70, "readable": 80 },
  "findings": [ { "severity": "medium", "where": "pr-body.md § Not covered",
                  "claim": "the visual-regression manifest reason is paraphrased",
                  "why": "the manifest says 'no baseline images'; the body says 'visual checks pending'",
                  "fix": "copy the reason verbatim" } ],
  "verdict": "pass", "confidence": "high" }
```
