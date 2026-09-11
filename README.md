# claude-swarm

A portable agent swarm that carries a GitHub issue from intake to a pull request an
approver merges, then writes down what it learned. It lives in its own repository and is
pointed at other projects; each project it works on gets a memory folder here, where
agents record how that codebase actually works and how you want work done in it.

**Scope ends at your merge.** No deploy, no release, no production access. Nine stages,
sequential roles, three human gates, one deterministic dispatcher — and a language
model never writes a mention, a label, a marker or a handoff.

Branch `v2` is the pipeline described here; `main` is v1 (mention-driven) and stays
runnable. `PLAYBOOK.md` is the policy; `pipeline.yml` is the routing data.

---

## The pipeline

    issue + swarm:ready
      └─ triage ─ requirements ─┤GATE 1┤─ design ─ architecture ─┤GATE 2┤─ build ─ test ─ security ─ release ─┤GATE 3 = merge┤─ retro

| Stage | Roles | Passes when |
|---|---|---|
| triage | `triage` | type/size/area/prio set; full or short path chosen |
| requirements | `analyst` + strong critic | ≥ 1 checkable acceptance criterion; refs grep-hit the requirements doc; critic ≥ 70 — **you approve** |
| design | `ux` → `a11y` | edge states covered; a11y checklist passes |
| architecture | `architect` → `threat-model` + critic | ADR, API contract, migration plan, flags, rollback exist; critic ≥ 70 — **you approve** |
| build | `planner` → `test-writer` → per lane `dev` → `code-review` | tests pinned red first, draft PR open, CI green on every reviewed head |
| test | device walkthrough → `qa` | CI green, coverage held, every AC has a passing test by name |
| security | scans → `security` → `compliance` | no true positive introduced by the branch |
| release | `release` + strong critic | PR ready, every artifact landed — **you merge** |
| retro | `retro` | post-mortem, ADR pointer and gotchas proposed as a memory PR |

A small bug or chore in one lane takes the **short path**: design, architecture, the
planner, both comment gates, the critics (except release's) and the evidence workflows
are skipped; you are woken once, to merge.

### Rework and brakes

Every backward edge shares **one budget of five per issue**; your own `/swarm reject`
and `/swarm redo` are free and reset it. A per-issue cost cap (75 USD) is a wait-state
that asks, not a death; a monthly minutes/dollars brake reads the account's real billing
figure. Full list in `PLAYBOOK.md` §5.

---

## Layout

    PLAYBOOK.md                 operating policy (marker <!-- swarm-playbook: v2 -->)
    pipeline.yml / .json        the stage graph as data — tiers, classes, artifacts, edges, limits, tool lists
    .github/workflows/          dispatch.yml (the reusable orchestrator), conformance.yml (CI for this repo)
    .claude/agents/             the PORTABLE roles — no project specifics, ever
    .claude/skills/             swarm-onboard, swarm-memory, swarm-tick (sweep lanes only)
    lib/                        GUARD, ROUTING (rendered from pipeline.json), OUTPUT-CONTRACT, AUDIT, GATES, STATE, EVIDENCE
    lib/sh/                     the dispatcher's scripts (resolve, begin, validate-result, advance, route, fire, evidence, watchdog, …)
    lib/jq/                     state transitions, result checks, renderers
    lib/hooks/                  PreToolUse path and command guards handed to the action as `settings:`
    lib/critic/                 rubrics for the critic runs
    lib/schema/                 JSON Schemas: pipeline, state, result, critic, swarm-config (+ defaults)
    lib/templates/              comment templates the dispatcher renders
    lib/conformance/            run.sh + ~110 cases against a fake gh; portability.sh; render-routing.sh
    templates/                  swarm-dispatch.yml (the project stub), swarm.yml (project config), swarm-probe.yml, evidence-workflow.md
    memory/github.com/<owner>/<repo>/    everything project-specific
    memory/_swarm-itself/       what the swarm learned about its own runtime

**The split that makes this reusable:** `.claude/agents/test-writer.md` says *pin the
test red with the project's marker before anyone fixes it*. A project's `gotchas/` says
*the typecheck in this repo is a false green because its config excludes the source
directory*. Only the second changes when you point the swarm somewhere else. Lane
names, workflow names, commands, the pin marker, test paths and the requirement-id
pattern all come from the project's `.github/swarm.yml`; the swarm never guesses them.

There is a test for this, and CI runs it (`lib/conformance/portability.sh`):

    grep -rilE 'meipadam|tsconfig\.check|pglite|react-native|cdk|maestro|gradle|android|semgrep|zap|jest|supertest|gitleaks|#[0-9]{2,}' \
      .claude/agents/ lib/ PLAYBOOK.md pipeline.yml pipeline.json templates/

plus, for every lane and workflow name in the fixture configs, the same grep. It must
return nothing. Examples in portable files use issue `#7`, PR `#9` and lanes `api`/`app`.

## Onboarding a project

**The project's half is a stub and a config file.** GitHub only runs workflows that
live in the repository receiving the event, so every project needs *a* dispatch
workflow — but not *this* one: `templates/swarm-dispatch.yml` calls `dispatch.yml` here
with five inputs and three secrets, and the guards stay in one place.

1. **Probe** — copy `templates/swarm-probe.yml`, run it once, write what it answered into
   `memory/_swarm-itself/v2-probe-results.md`, delete it. It settles the chain actor,
   the override token, the model map, the transcript after a kill, and (once the stub is
   on the default branch) what the App token can reach.
2. **Stub** — copy `templates/swarm-dispatch.yml` to `.github/workflows/swarm-dispatch.yml`;
   set `workflow_run.workflows` to your evidence workflow names. Write-class stages need
   the stub **merged to the default branch** before their first run (the App-token
   exchange refuses a workflow file that differs from the default branch's).
3. **Config** — run `swarm-onboard`; it writes `memory/github.com/<owner>/<repo>/` and
   generates `.github/swarm.yml` from what it verified by running: lanes (directories
   with their own lockfile), commands, test paths, sensitive paths, the CI gate files as
   protected paths.
4. **Labels and state branch** — `lib/sh/labels.sh install <owner/repo>`;
   `lib/sh/state.sh init-branch <owner/repo>`.
5. **Three secrets** on the project — `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`;
   expires yearly, the pipeline says `blocked:auth` when it does); `SWARM_TOKEN` (a
   fine-grained PAT on this repo: Contents and Pull requests read/write, optionally the
   account's Plan: read so the monthly brake can read billing); `SWARM_STATE_KEY`
   (`openssl rand -hex 32`; the state file's signing key — never in a job with a model).
6. **Repository settings** — *Actions → Workflow permissions* set to read-only, so a
   project workflow can never hold a write token by omission.
7. **Control issue** — a pinned Swarm Control issue; closing it or labelling it
   `swarm:halt` is the kill switch. Its body carries no config.
8. **Smoke issue** — pick a `size:S` bug, add `swarm:ready`, and watch: state comment,
   triage → requirements on the short path, the test-writer's draft PR, CI once per
   push, dev → code-review → qa → release gate; merge; the memory PR appears.

Read the memory `swarm-onboard` produced before step 8. Generic filler means the
onboarding failed — fix it now, because every later run trusts it.

## How it runs — measured, not assumed

Every stage is one Actions run: `resolve` claims the dispatch in the signed state file
and posts the working comment; a `run-read` or `run-write` job checks out the project,
gets the swarm tree as an artifact, and runs `claude-code-action` with the role's brief;
`advance` re-validates the result from fresh checkouts, records cost and model from the
execution file, routes, and fires the next stage with `gh workflow run`. Details:
`lib/ROUTING.md`, `lib/STATE.md`, `lib/EVIDENCE.md`, `PLAYBOOK.md` §10–11.

What the probe settled so far: the chain actor is `github-actions[bot]` (covered by
`allowed_bots`); the `github_token` override bounds read roles to the job's permissions
(403 on a comment, refused push); `--model` is honoured under the OAuth token; the
execution file survives a `--max-turns` overrun; a checkout's `.claude/settings.json`
hooks **do** run headless, so `begin.sh` restores project configuration from the merge
base before any model runs. Still open until the stub is on the default branch: whether
the App token can merge a PR or push a workflow file — gate 3 is detective either way.

## Status

| | |
|---|---|
| v1 (mention-driven, `main`) | ran one issue end to end; stalled silently twice on handoffs — the reason v2 exists |
| v2 spec | 17 sections, three adversarial reviews applied; `memory/_swarm-itself/v2-design.md` |
| v2 dispatcher, scripts, roles, conformance | on branch `v2` |
| Probe on the first project | runs 1–4 done (`memory/_swarm-itself/v2-probe-results.md`): R1–R4, R5a, R6, R30 answered; R5b not exercisable (a hard kill leaves no execution file — tolerated); R28/R29 deferred to switch-on, measured with `templates/swarm-probe.yml`'s `write` job once the stub is on the default branch |
| First project switched on | not yet |

### What to expect per month

Billing rounds every job up to a minute, and a hop costs ≈ 5.5 billed minutes of
dispatcher overhead on top of the model's time. A full-path issue that touches the
client lane runs ≈ 280–360 runner minutes and $35–50 in model cost; a backend-only one
≈ 240–300 and $30–42; a short-path issue ≈ 150–200 and $10–15; each review or CI-red
rework round adds ≈ 45 minutes and $4–5; the watchdog and event-only runs add 60–120
minutes a month. At the 1,500-minute brake that is **≈ 4 full issues or ≈ 8 short ones
a month** — and on the Free plan the whole account's 2,000 minutes count, so reaching
them freezes every workflow in the repository. The first retro replaces these estimates
with measurements.
