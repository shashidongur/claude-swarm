---
name: decisions
description: Choices already settled for this project, so later runs do not relitigate them
metadata:
  type: decision
---

## The human gate is merge, not approval — 2026-09-03

Every agent PR is authored by `shashidongur`, who is the **sole collaborator**, and
GitHub forbids approving your own pull request. `reviewDecision` is empty on all six PRs
in this repo's history, and `GET /branches/main/protection` returns
`403 Upgrade to GitHub Pro`. So "approved" is undetectable; `mergedAt != null` on
`base=main` is the signal.

**Consequence worth restating:** there is no server-side enforcement here — no branch
protection, no rulesets, no required review. Nothing but the routine's allowed-tools
list stops an agent merging to main. The perimeter is the allowlist.

**If enforcement is ever wanted:** give the swarm a second identity (a bot account or
GitHub App) as PR author. That is the only change that makes approval possible and lets
a paid plan require it.

## Rework budget: five shared, human unlimited — 2026-09-03

Review → Build, Test → Build, and Demo → Spec share one budget of five per issue. The
owner's change requests are unlimited, never counted, and reset the budget to five —
without the reset, late feedback would block work almost immediately and the owner's own
comment would be the thing that stopped it.

## A demo failure returns to Spec, not Build — 2026-09-03

If the app works and does the wrong thing, the criteria were wrong. Re-entering at Build
rebuilds the same misunderstanding. Owner's decision, chosen over sending it to Build
and over blocking immediately.

## The untracked regression suites are not all landable as-is — 2026-09-03

The 38 `issueNN-*` files were written on `gnhf/you-will-take-the-ro-7770fd`, which
diverged from `main` on 2026-08-21 and is **26 commits behind**. Validated against
current `main` in a clean worktree:

- **19 of 21 backend suites pass** and are landable unchanged.
- `issue54-role-guards` — all six `it.failing` pins now report *"Failing test passed"*.
  The guards it asked for **landed on main**. Remove `.failing` and it becomes a plain
  regression suite.
- `issue52-master-subscriber-listing` — three plain `it` cases now get 403 instead of
  200, because that same guard was applied to `GET /memberships/me`, which is dual-role.
  Filed as issue #66.
- `Issue58.masterSkeletons.test.tsx` is **already on main**; do not re-add it.
- The mobile suites target screens that `main` has since changed (Dashboard,
  StudentProgress, ManageSessions, CourseEdit, AddStudent) and are unvalidated until CI
  is green again.

**How to apply:** land the backend suites in tranches with their results, never as one
38-file drop. Validate against `main`, not against the branch they were written on.

## Pipeline v2: the gates are owner comments, and gate 3 is a merge by an approver — 2026-09-06

Three human wake-ups on the full path: `/swarm approve` after requirements, after
architecture, and the merge; one on the short path. Approvers are `.github/swarm.yml
approvers.*`, empty here, so every gate falls back to the repository owner (a `User`).
**Gate 3 counts only when an approver merged**: a merge by `claude[bot]` or anyone else
is `blocked:perimeter` with the revert command, no retro, no branch delete. This
supersedes "the human gate is merge, not approval" above in one respect — the swarm now
checks *who* merged, because the write class holds an App token that may be able to
merge its own PR (probe R29 answers this once the stub is on `main`).

## Reviewer ≠ author, by model tier — 2026-09-06

`code-review` runs on the strong tier (`claude-opus-5`), `dev` on the default
(`claude-sonnet-5`); `must_differ_from: dev` is conformance-checked, and the model
actually used is recorded per dispatch from the execution file. Probe run 2 confirmed
`--model` is honoured under the OAuth token (`modelUsage: ["claude-opus-5"]`), so
`require_model_map` stays `false` with `models.honoured` defaulting to true.

## Memory is written through a pull request at retro — 2026-09-06

The retro role proposes `postmortems/<N>.md`, an ADR pointer and ≤ 3 gotchas under
`gotchas/auto/`; `advance` opens a PR on claude-swarm with `SWARM_TOKEN` that the owner
merges. Machine-written memory is read fenced until promoted. Nothing lands on the
executable branch without a human reading it.

## The PR is opened by the test-writer, and CI runs once per push — 2026-09-06

The test-writer (App token) makes the first push and `gh pr create --draft` in the same
turn; from then on only roles push, and the dispatcher stages its artifacts on
`swarm/state` to land with the next role push. `ci.yml` triggers on `pull_request` and
`push: main` only — **no `push: claude/**` trigger** — so each head runs CI once
(`pull_request: opened` covers the first push within seconds). A `github.token` push to
a branch with an open PR would leave its CI run in "approval required".

## Red CI is baselined, not fixed by the dev — 2026-09-06

Mobile jest failures inside `mobile/jest.baseline.json` (recorded in coverage mode: 91
in that mode vs 52 without), audit advisories inside the two `audit.baseline.json`
files, and Semgrep findings present at the merge base are not "red"; a secret always
is. The gate files are protected paths. Reason: on `main` today `npm audit
--audit-level=high` exits 1 on both packages (9 high + 1 critical / 20 high + 2
critical) and 52–91 mobile tests fail by design — an unbaselined gate would send every
dev into rework it cannot fix.

## The state file is signed, and `.claude/` is restored before every role — 2026-09-08

`SWARM_STATE_KEY` signs `issues/<N>.json`; only LLM-free jobs hold it. Probe run 2
showed a `.claude/settings.json` SessionStart hook from the checkout **runs headless**
(`settingSources: ["user", "project", "local"]`, and `.mcp.json` servers are enabled),
so `begin.sh`'s restore of `.claude/`, `CLAUDE.md`, `.mcp.json`, `.claude-plugin/` from
the merge base is load-bearing, not belt-and-braces.

## Write-class stages need the stub on `main` — 2026-09-08

The OIDC → App-token exchange refuses a calling workflow file that differs from the
default branch's ("Workflow validation failed … identical content"). So the v2 stub is
merged to `main` before the first write role runs; read-class stages (override token)
work from any branch. R28/R29 (what the App token can reach, whether it can merge or
push workflow files) are measured then, and the detective controls assume the worst
until they are.
