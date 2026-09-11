# Rubric: report

Scores a qa, security or compliance report. Off by default — those verdicts are
mechanically constrained (CI conclusion, manifest reasons); switch it on in
`pipeline.yml`. Threshold **65**. The critic reads `.swarm-run/brief.md`,
`.swarm-run/result.json`, the artifacts under `.swarm-run/artifacts/` and this file —
nothing else — and writes `.swarm-run/critic.json` with the `Write` tool.

## Dimensions

| key | weight | definition |
|---|---|---|
| `repro` | 0.40 | every failure the report sends back has a repro: the test name and its failing output, the flow and its screenshot path, or the finding's `path:line` — and names the lane that owns it |
| `verified` | 0.30 | no claim rests on the report's own authority: every "passes", "mitigated" or "false positive" cites an evidence path, a `path:line` or a command with its output |
| `not_covered` | 0.30 | the not-covered list carries every evidence manifest reason verbatim, classifies environment failures there rather than as rework, and states the platform exclusions |

### repro (0.40)

- **40** — "tests fail" with no name; a rework with no lane; a scanner finding sent back
  without its line.
- **70** — every failure has a name and output; one repro is the summary line, not the
  assertion.
- **90** — every repro is the assertion (or scanner line) and the input that produces it;
  product and environment failures are separated with reasons.

### verified (0.30)

- **40** — an AC marked covered whose test is not in the results by name; "false positive"
  with no reason; a coverage number that matches no summary.
- **70** — every claim cites something; one citation is to a summary rather than the
  underlying result.
- **90** — every claim opens to the evidence file or `path:line`; the contract check is
  cited or explicitly "no contract check configured".

### not_covered (0.30)

- **40** — a manifest reason missing or paraphrased; an environment failure sent to the dev.
- **70** — every reason present; one platform exclusion implied rather than stated.
- **90** — every reason, exclusion and `Not exercised: …` sentence present, verbatim,
  where the next reader will look.

## Rules

- Cite `where` for every finding: `qa-report.md § ACs AC-7-2`, `security-report.md §
  Findings row 3`, `compliance.md § Fields email`. A finding without a `where` does not
  exist.
- **A claim without a checkable path or command scores ≤ 40 on grounded** — in this
  rubric the grounded dimension is `verified`.
- Every area the evidence did not exercise must be stated in the report as one sentence
  per area, verbatim in this form: `Not exercised: <area> — <reason>.` A report that
  implies coverage it does not have scores ≤ 40 on `not_covered` and is a `high`
  finding. What you could not check yourself is a `low` finding whose `claim` starts
  `Not exercised by the critic:` and lowers `confidence`.
- `score` = round(0.40·repro + 0.30·verified + 0.30·not_covered). `verdict` = `pass` iff
  `score ≥ 65` and no `high` finding.
- `confidence`: `high` when every cited evidence file was opened; `medium` when some
  rested on plausibility; `low` when the evidence directory was missing (`low` + `fail`
  goes to the human, not to a rework).

## Output — `.swarm-run/critic.json`, written with the `Write` tool, once

```json
{ "v": 2, "issue": 7, "stage": "test", "target_key": "7:test:qa:1",
  "rubric": "report", "model": "<model id from the prompt>",
  "score": 74, "threshold": 65,
  "dimensions": { "repro": 80, "verified": 70, "not_covered": 70 },
  "findings": [ { "severity": "medium", "where": "qa-report.md § ACs AC-7-4",
                  "claim": "marked covered but its test name is absent from the CI test json",
                  "why": "evidence/CI/SUMMARY.md lists 213 tests; the named test is not among them",
                  "fix": "move AC-7-4 to not covered or cite the test that ran" } ],
  "verdict": "pass", "confidence": "high" }
```
