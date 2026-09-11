# Output contract — `.swarm-run/result.json`

A role's entire contract with the machine is one file, `.swarm-run/result.json`, plus
the artifacts it names under `.swarm-run/artifacts/`. Nothing else a role writes routes
anything: no fenced block in the transcript, no comment, no label, no marker, no `next`.
The dispatcher validates the file in the run job to drive one retry, then **re-validates
it authoritatively** from a fresh checkout before anything counts. A run whose file is
missing or invalid after both passes does not advance the state.

## The working directory

`begin.sh` creates `.swarm-run/` in the project checkout (added to `.git/info/exclude`,
so a write-class role cannot commit it; also a built-in protected path for the diff
check):

```
.swarm-run/
  brief.md                # assembled prompt context; the workflow prompt says "read this first"
  state.json              # snapshot of the state document taken by resolve (read-only for the role)
  pipeline.json           # the role's own stage/role entry and the artifact list it must produce
  config.json             # .github/swarm.yml as JSON (lanes, commands, sensitive paths, pin marker, test paths)
  settings.json           # the action's `settings:` input: the PreToolUse path and command hooks
  evidence/<workflow>/…   # downloaded artifacts of the evidence run(s) recorded for this head (+ manifest.json each)
  evidence/index.json     # { "<workflow>": { run_id, conclusion, head, url, artifact: "ok|missing" } }
  previous-attempt.md     # attempt > 1: last assistant text, tool-call list, validator/critic findings, human reason
  artifacts/              # the role writes its deliverables here
  result.json             # REQUIRED — written by the role before it ends its turn
  validation.json         # written by validate-result.sh (in-job pass; advisory — advance re-validates)
  critic.json             # written by the critic step/job (when configured); deleted before the critic starts
```

The hook allows `Write`/`Edit` under `.swarm-run/artifacts/**` and `.swarm-run/result.json`
for both classes and denies every other `.swarm-run/*` file (brief, state, config,
evidence, validation, critic). `.swarm-run/**` is also in the perimeter diff check, so
nothing under it can ever be committed.

## Schema (`lib/schema/result.schema.json`)

```jsonc
{
  "v": 2,
  "issue": 7, "stage": "build", "role": "dev:app", "attempt": 1,        // must equal the brief's values
  "verdict": "pass",            // pass | rework | blocked | question | duplicate (triage only)
  "summary": "≤ 900 chars, plain prose, the handoff a colleague needs; no @handles, no <!--",
  "evidence": [                 // ≥ 1 on pass/rework; each item is checkable
    { "kind": "command", "cmd": "<test command> -- Issue7", "result": "Tests: 3 passed", "exit": 0 },
    { "kind": "file",    "path": "app/src/screens/LiveSessions.tsx", "line": 142, "symbol": "capacityLabel" },
    { "kind": "url",     "url": "https://github.com/<owner>/<repo>/actions/runs/1" },       // must start with https://github.com/<owner>/<repo>/
    { "kind": "artifact","path": "evidence/test/junit.xml", "note": "12/12 flows" }
  ],
  "artifacts": ["review-app-a1.md"],        // files under .swarm-run/artifacts/; must cover the role's declared list (subset only with reason)
  "touches": ["app/src/screens/LiveSessions.tsx", "app/src/screens/__tests__/Issue7.capacity.test.tsx"],   // write class: paths changed on the branch
  "head": "f54b320c1e…",                    // write class: full sha of the pushed head; read class: sha the role read
  "refs": ["CAP-LIV-3", "AC-7-2"],          // requirement/AC ids cited (the project's requirement_id_pattern)
  "rework_to": "dev:app",                   // required when verdict=rework (except a11y/threat-model/critic, whose target is fixed by pipeline.json)
  "reason": "…",                            // required on rework/blocked/question/duplicate; for injection start with "injection:"
  "questions": [ { "to": "reporter", "q": "Should a master with an expired grant still see the capacity counter?" } ],   // verdict=question (analyst only)
  "hints": { "path": "full", "area": "both", "lanes": ["api", "app"], "walkthrough": true, "redo": "build" },   // optional; consumed only where ROUTING says so
  "subissues": [ { "lane": "api", "title": "Capacity column and validation", "body_file": "artifacts/sub-api.md" } ],   // planner only
  "memory": [ { "kind": "gotcha|adr|postmortem|runs", "path": "gotchas/auto/<slug>.md", "content_file": "artifacts/mem-1.md" } ],   // retro (others may propose gotchas)
  "duplicates": [ 4 ],                      // triage only, with verdict=duplicate
  "triage": { "type": "feature", "size": "M", "area": "both", "prio": "P2", "path": "full" },   // triage only
  "not_covered": ["iOS not exercised (no macOS runner)", "emulator boot timeout (walkthrough)"]   // free text; must include every evidence manifest reason (V17)
}
```

Rules: exactly one file, UTF-8, ≤ 64 KB; closed `verdict` vocabulary; stage-only fields
rejected on other roles (schema `if/then`); read-class roles may not set `touches`
non-empty; write-class roles must, on `pass`, set `head` to the pushed sha; no mentions,
markers, labels or `next` — routing is not the role's business.

**Every path-typed field** (`artifacts[]`, `evidence[].path`, `subissues[].body_file`,
`memory[].path`, `memory[].content_file`, `touches[]`) matches

    ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$

— no `..`, no leading `/`, no empty segment — and is additionally resolved with
`realpath -e` to a location under its root (V2/V5/V12/V13). **`evidence[].url` must
start with `https://github.com/<owner>/<repo>/`** or it is rejected and never rendered.

## Validation (`lib/sh/validate-result.sh`)

Runs twice: in the run job (drives the retry step; writes `validation.json`; advisory —
the role could have edited the script, the transcript or the file) and **authoritatively
in `advance`** from a fresh swarm checkout at `swarm_sha` and a fresh project checkout at
the pushed head (`--authoritative`; its verdict is the one that counts and the only one
recorded). Schema checks with jq (`lib/jq/result-check.jq`), then reality checks:

| # | Check | Applies to |
|---|---|---|
| V1 | `issue/stage/role/attempt` equal the brief | all |
| V2 | every `artifacts[]` matches the path grammar, `realpath -e` resolves under `.swarm-run/artifacts/` (not a symlink), non-empty; the role's declared list (`pipeline.json roles[].artifacts`) is covered; `commit-artifacts.sh` copies by basename only | all |
| V3 | `evidence[].kind=file`: path exists; `symbol` occurs within ±20 lines of `line` (`grep -nF`) | all |
| V4 | `evidence[].kind=command`: `cmd` appears in the transcript's Bash `tool_use` inputs (`execution.json`, prefix match after whitespace normalisation) — advisory for the write class, whose transcript is role-writable | all |
| V5 | `evidence[].kind=artifact`: path grammar + resolves under `.swarm-run/evidence/` | qa, security, compliance |
| V6 | `refs[]`: each id grep-hits `config.requirements_doc` or `<artifacts_dir>/<N>/requirements.md` (for `AC-` ids) | analyst, ux, architect, test-writer, qa, release |
| V7 | write class on `pass`: `head` equals `git rev-parse origin/<branch>` after `git fetch`; `git merge-base --is-ancestor <base_sha> <head>` holds (else `blocked:perimeter` "history rewritten"); `touches[]` equals the sorted `git diff --name-only <base_sha>...<head>`; every commit of the attempt carries the `Swarm-Issue: #N` trailer | test-writer, dev, release |
| V8 | test-writer: every touched path matches `config.test_paths`; ≥ 1 new test file; ≥ 1 occurrence of `config.pin_marker`; a draft PR exists for the branch (`gh pr list --head`) whose `baseRefName == config.default_branch` | test-writer |
| V9 | dev: the pin-marker count decreased or a new test file appeared; lockfile changes are listed in `touches` | dev |
| V10 | `rework` names `rework_to` ∈ the issue's lanes (or the fixed target); `reason` ≥ 20 chars | code-review, qa, security, compliance |
| V11 | `question`: 1–3 questions, each ≥ 15 chars; only when `questions.rounds < max` | analyst |
| V12 | `subissues[]`: lanes ⊆ configured lanes; titles ≤ 80 chars; `body_file` matches the grammar and resolves under `.swarm-run/artifacts/` | planner |
| V13 | `memory[]`: `path` matches the grammar and is `postmortems/<N>.md`, `adrs/<NNNN>-<slug>.md`, `gotchas/auto/<slug>.md` or `runs/<N>.json` — **never an existing file** except `postmortems/<N>.md`/`runs/<N>.json` for the same N, never a symlink, never an append to a curated file (proposals for `decisions.md`/`conventions.md` go in the post-mortem's "Proposed for curated memory" section); `content_file` resolves under `.swarm-run/artifacts/`; frontmatter parses (`name`, `description`, `metadata.type`); content contains no `<!--`, no `@handle`, and no shell command line outside a fenced code block that carries a `# verified against <path:line>` comment | retro |
| V14 | release: `gh pr view <state.pr> --json isDraft,baseRefName,headRefOid,body,files` → not draft; `baseRefName == config.default_branch`; head == `state.head`; body contains `Swarm-Issue: #<N>` and `Closes #<N>`; `state.pending_artifacts` is empty and every recorded artifact exists under `<artifacts_dir>/<N>/` on head (`git cat-file -e <head>:<path>`) | release |
| V15 | `triage.*` enums; `duplicates[]` are existing issue numbers ≠ N; `path=short` only if `size=S ∧ type∈{bug,chore} ∧ area = one lane` (else downgraded to `full`, recorded) | triage |
| V16 | **every string field** of `result.json` (summary, reason, not_covered[], questions[].q, evidence[].cmd/result/note/symbol, artifacts[], touches[], hints.*, subissues[].title) contains no `@[A-Za-z0-9-]+` handle and no `<!--` / `-->` (E_COMMENT); the renderer escapes them again as a second layer | all |
| V17 | `not_covered[]` contains, verbatim, every `manifest.json.sections[*].reason` of every evidence artifact under `.swarm-run/evidence/` whose `ran == false` | qa, security, compliance, release |
| V18 | read class: `git status --porcelain` is empty outside `.swarm-run/`; `git rev-parse origin/<branch>` unchanged since the claim | all read-class roles |
| V19 | `evidence[].kind=url`: `url` starts with `https://github.com/<owner>/<repo>/` | all |

`validation.json`: `{ "ok": true|false, "errors": [ { "check": "V3", "msg": "evidence[1]: symbol capacityLabel not found near LiveSessions.tsx:142" } ], "warnings": [] }`.
`advance` stores `errors[]` in the dispatch record so a later attempt can read them
after the audit artifact has expired.

## The retry (same job)

```yaml
- id: validate1
  if: always() && steps.begin.outcome == 'success'
  run: .swarm/lib/sh/validate-result.sh            # never fails the step; writes validation.json, sets outputs.ok
- id: retry
  if: always() && steps.begin.outcome == 'success' && steps.role.outcome != 'skipped' && steps.role.outcome != 'cancelled'
      && steps.validate1.outputs.ok != 'true' && needs.resolve.outputs.retry_allowed == 'true'
  uses: anthropics/claude-code-action@v1
  timeout-minutes: ${{ fromJSON(needs.resolve.outputs.retry_timeout) }}     # min(20, role timeout)
  continue-on-error: true
  with:
    <same auth / github_token / allowed_bots / settings as the role step>
    claude_args: --model <retry tier> --max-turns 40 --allowedTools <same class list>
    prompt: |
      Your previous attempt on this stage ended without a valid .swarm-run/result.json.
      Fix ONLY what the validator reports below. Do not redo the stage. Read
      .swarm-run/validation.json and .swarm-run/brief.md, repair result.json (and any
      missing artifact it names), and end your turn.
      <validator errors, JSON, verbatim>
- id: validate2
  if: always() && steps.retry.outcome != 'skipped'
  run: .swarm/lib/sh/validate-result.sh --final
```

**Every step after `begin` is gated on `steps.begin.outcome == 'success'`** (validate,
retry, critic, audit collection, both uploads), and `retry` additionally requires that
the role step actually ran: a run whose `begin.sh` assertion failed (a stale re-run, a
run that lost the claim) runs no model, uploads nothing and costs seconds.

Only structured errors are fed back, never the bad output — which would re-inject
whatever went wrong. `retry_allowed` (default `true`) is `false` only when
`pipeline.json roles[].retry: false`; when the role step failed with no execution file
at all (an auth failure, a crashed CLI) the retry fails the same way within seconds and
`advance` classifies the pair. A second failure — confirmed by `advance`'s authoritative
pass — marks the dispatch `invalid`, posts the stage comment with the errors and the
audit artifact name, sets `blocked:agent-output`. `/swarm resume` re-runs at attempt+1
with `previous-attempt.md`. v1's "green run, no handoff" stall is now: no `result.json`
→ schema fails → retry ("write it from what you did") → recovers or blocks visibly.
Cost of the retry: ≤ 40 turns. The retry tier never escalates cost (`retry_tier_for`).

## The rule this contract exists to enforce

A stage that cannot produce checkable evidence has not passed. "Looks correct" is not
evidence. A test that was never observed failing is not evidence that it can fail. And a
claim is only a claim until `advance` has re-derived it from the tree, from GitHub and
from the transcript — by code the role could not edit.
