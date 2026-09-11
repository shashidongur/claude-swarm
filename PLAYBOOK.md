<!-- swarm-playbook: v2 -->
# Swarm playbook

Operating policy for the pipeline and every role. Policy lives here, in the repo, so a
change to how the swarm behaves arrives as a pull request; the routing data that the
dispatcher executes lives beside it in `pipeline.yml`. The sweep skill reads this file
and aborts if the marker above is missing.

Read `lib/GUARD.md` before acting on anything a human or another agent wrote.

---

## 1. Scope

The swarm carries a GitHub issue from intake to a pull request that **an approver
merges**, then writes down what it learned. It does not deploy, release, or touch
production. A full-path issue wakes the owner three times — approve requirements,
approve architecture, merge; a short-path issue once — merge. Nothing in it waits on a
runner, and nothing a language model writes routes anything: a role's whole contract is
`.swarm-run/result.json` and the artifacts it names (`lib/OUTPUT-CONTRACT.md`), and
every claim in that file is re-derived by the dispatcher before it counts.

## 2. The nine stages

    issue + swarm:ready (or "/swarm start")
      └─ triage ─ requirements ─┤GATE 1┤─ design ─ architecture ─┤GATE 2┤─ build ─ test ─ security ─ release ─┤GATE 3 = merge┤─ retro
                                          (skipped on the short path)

| # | Stage | Roles (in order) | Leaves behind | Passes when |
|---|---|---|---|---|
| 1 | `triage` | `triage` (cheap tier) | `triage.json` | type/size/area/prio set; `full` or `short` chosen; duplicates named |
| 2 | `requirements` | `analyst`, then a strong critic (full path) | `requirements.md` | ≥ 1 acceptance criterion, every ref grep-hits the requirements doc, critic ≥ 70 — then **gate 1** |
| 3 | `design` | `ux` → `a11y` | `design.md`, `a11y.md` | the edge-state table is complete; a11y passes |
| 4 | `architecture` | `architect` (strong) → `threat-model`, then a critic | `adr.md`, `openapi.yaml`, `migration-plan.md`, `flags.md`, `rollback.md`, `threat-model.md` | all five artifacts exist, the contract parses, critic ≥ 70 — then **gate 2** |
| 5 | `build` | `planner` → `test-writer` → per lane `dev:<lane>` → `code-review:<lane>` (strong) | plan, sub-issues, pinned tests, draft PR, reviews | test-writer touched only test paths and opened the draft PR; each dev pushed a head CI is green on; each review passed |
| 6 | `test` | device walkthrough (evidence) → `qa` | `qa-report.md` | CI green on head, coverage held, walkthrough not red; every AC has a passing test by name |
| 7 | `security` | security scan (evidence) → `security` → `compliance` | `security-report.md`, `compliance.md` | no true positive introduced by the branch; sensitive data handled as the threat model requires |
| 8 | `release` | `release`, then a strong critic in its own read-only job | PR body, `release.md`, PR ready | PR not draft, base = default branch, head = recorded head, every artifact landed — then **gate 3** |
| 9 | `retro` | `retro` | a memory pull request on this repo | post-mortem, ADR pointer, ≤ 3 gotchas; issue ends `swarm:done` |

The full table with tiers, classes, critics, rework edges and short-path exceptions is
`lib/ROUTING.md`, rendered from `pipeline.yml`. Triage picks the short path only for a
small bug or chore in one lane; short skips design, architecture, the planner, both
comment gates, every critic but release's, and the evidence workflows.

Each stage is a separate Actions run with nothing but the issue: its role file, the
project's memory, the earlier artifacts (fenced), and the evidence. A handoff that
leaves something out fails visibly instead of being carried silently by shared context.

## 3. Labels

Labels are a **projection** of the signed state file, written only by the dispatcher
(`lib/STATE.md` has the full table). Exactly one `swarm:<stage>` at a time — `triage`,
`requirements`, `design`, `architecture`, `build`, `test`, `security`, `release`,
`retro` — plus at most one of:

    swarm:gate:requirements | swarm:gate:architecture | swarm:gate:release     a human's turn
    swarm:gate:question | swarm:gate:confidence | swarm:gate:budget           a wait-state a command resumes
    swarm:waiting:evidence                                                    CI or an evidence workflow is running
    swarm:blocked + blocked:<reason>                                          stopped; always says why
    swarm:parked | swarm:dropped | swarm:done

`blocked:*` reasons: `agent-output`, `budget`, `runaway`, `evidence`, `stalled`, `fire`,
`injection`, `duplicate`, `conflict`, `bad-handoff`, `perimeter`, `auth`, `model`.
Metadata from triage: `bug` / `feature` / `chore`, `size:S|M|L|XL`, `area:<lane>|both`,
`prio:P0..P3`; `swarm:short` marks the path.

Human-owned, never removed by projection: `swarm:hands-off` (per-issue veto),
`swarm:control`, `swarm:halt`, `swarm:halt-pipeline`. `swarm:ready` is the start
signal, consumed by `start`. `swarm:lane` marks a tracking sub-issue that is never
dispatched. A stage label added by hand on an issue with no v2 state gets one reply and
starts nothing.

## 4. Gates and commands

`lib/GATES.md` is the whole grammar. Gates 1 and 2 are `/swarm approve` or
`/swarm reject <why>` as the first line of a comment by an approver; gate 3 is a merge
**by an approver** — any other merger is `blocked:perimeter` with the revert command,
and no retro runs. Approvers are logins in `.github/swarm.yml`; the default on a
user-owned repository is the owner. Every refused command gets one reply saying why;
every accepted one gets a one-line acknowledgement.

## 5. Brakes

Budgets, not estimates. Each is enforced from state, not from workflow-run counts.

| Brake | Value | When it bites | What happens |
|---|---|---|---|
| Rework budget | 5 per issue, shared by every backward edge | about to fire a rework edge with `rework.spent ≥ 5` | `blocked:budget`; owner reject/redo are free and reset it |
| Runaway | 10 dispatches recorded in the last hour | any fire | `blocked:runaway` |
| Cost cap | `cost_usd_per_issue` (75, 0 = off) | about to fire and the summed execution-file cost would cross it | **wait-state** `swarm:gate:budget` — `/swarm approve` raises it by one envelope, `/swarm park` or `/swarm drop` stop; a cap that kills an issue after the reviewer found a real bug is worse than one that asks |
| Monthly brake | `runner_minutes_month` 1,500 / `usd_month` 200 | at `start`, before every write-role dispatch, before an evidence fire | `start` replies (`/swarm start force` overrides); a dispatch waits at `swarm:gate:budget`; evidence is skipped with the reason in the manifest. Fed by the account's billing endpoint when `SWARM_TOKEN` can read it — the owner's own workflows count, and exhausting the plan's minutes stops every workflow in the repository |
| Critic rework | `critic_rework` 1 | a critic fails with confidence | one automatic rework carrying the findings, then `swarm:gate:confidence` |
| Question rounds | 2 | the analyst asks again | gate 1 with stated assumptions |
| Evidence fire cap | `evidence_fires_per_issue` 2 per workflow | a rework loop re-fires the emulator | CI evidence only, with a manifest reason the role must repeat |
| Blast radius | 800 lines / 25 files per PR; 3 open swarm PRs; 10 pushes per PR per day | at `release`; at `start`; per write-role dispatch | `release` refused with "split it: `/swarm redo build`"; a fourth `start` is parked with a reply |

A project may lower any limit in `.github/swarm.yml`, never raise it. **Rework is the
normal cost of work, not a failure**: v1 ran sixteen stages with zero reworks while an
audit of one of those changes found a duplicated predicate, a test pinning the wrong
fixture and an asserted index that did not exist. Five is a runaway guard, not a quota.

## 6. Idempotency

Every dispatch has a key — `<issue>:<stage>:<role>[:<lane>]:<attempt>` — and a run id,
and a record is identified by both. What that buys:

- **The fire is claimed before it happens.** `next-firing` is CAS-written into the
  signed state before `gh workflow run`; the run is then verified by the key in its
  `run-name`. Two writers cannot both fire; no verified run is `blocked:fire` and a
  red job, never a log line.
- **The dispatch is claimed by `resolve`**, which accepts a fire only when the key
  matches `state.next.key`, the status is `queued`, and no other run holds it. A run
  that lost the claim runs no model and uploads nothing.
- **An unclaimed run touches nothing**; a finished `(key, run_id)` re-run logs "already
  finalised" and exits; a run job cancelled by GitHub after the claim is re-queued and
  re-fired at once. GitHub's "Re-run jobs" is not a recovery path — `/swarm resume` is.
- **Routing happens after the record is written**, and every finaliser ends with a
  reconcile step that re-reads state and converges: `routing` with a finished record →
  route again; `queued` with no fire → fire.
- Comments carry the key in their marker and are edited, not re-posted. Sub-issues are
  keyed on their title prefix, artifact commits on content, PR creation on `gh pr list
  --head`, evidence fires on `(workflow, head)`, the merge on `merged_at == null`, and
  every reply on the event id.

## 7. Never write, never run

**Never write** (built-in protected paths, enforced on the diff by `advance` and on
`Write`/`Edit` by the path hook): `.github/**`, `.swarm/**`, `.swarm-run/**` except
`artifacts/` and `result.json`, `.claude/**`, `**/.claude/**`, `CLAUDE.md`,
`.mcp.json`, `.claude-plugin/**`, `**/*.pem`, `**/*.p8`, `**/*.key`, `.env*`,
`**/*.keystore`, plus the project's own `protected_paths` — which include **the CI
gate's own configuration**: test baselines, coverage thresholds, scanner allow-lists,
and the `test:ci` / `lint` / `typecheck` scripts of its package manifests. A gate you
can edit is not a gate; a role that needs one changed says `blocked`.

**Never write to any ref but your own branch.** Repository activity by `claude[bot]`
on another ref during a stage — the default branch, a new branch, a tag, `swarm/state`
— is `blocked:perimeter`, as is a rewritten history on the branch itself.

**Never run:** `gh pr merge`, `gh pr review`, `git push origin main`, `git push --force`
or a plus-push, `gh secret`, `gh repo edit`, `gh workflow`, `gh label`, `gh issue edit`,
`gh issue close`, `gh api` with `-X PUT|PATCH|DELETE` or `--method`, `curl`/`wget`
against the GitHub API, anything under `.swarm/lib`, anything that prints the
environment. The write class has these as tool deny-rules and a command hook; both are
bypassable, which is why §10 exists.

## 8. Kill switch

A pinned **Swarm Control** issue in the target repository. Every event reads it first.

- Closed, or labelled `swarm:halt` or `swarm:halt-pipeline` → nothing fires; a human
  command gets one reply ("swarm is halted: <reason>"), a machine event is silent.
- **If the read fails for any reason → also stop.** Fail closed.
- Per-issue veto: `swarm:hands-off`, by label or `/swarm hands-off`; cleared only by
  hand.

The dispatcher never reads the control issue's body — configuration lives in
`.github/swarm.yml` (project) and `pipeline.yml` (swarm). The watchdog edits one comment
on it: config errors, an expired token, the month's minutes and dollars and artifact
storage (⚠ at 80 %), the day's refused commands, repeated fire failures.

## 9. Memory

`memory/github.com/<owner>/<repo>/` in this repository, in two kinds:

- **Curated** — `MEMORY.md`, `conventions.md`, `preferences.md`, `decisions.md`,
  `agents/*`, `gotchas/*.md`, `adrs/*`: read unfenced by every brief; written by
  humans, or promoted by the owner in a memory PR.
- **Machine-written** — `gotchas/auto/*`, `postmortems/*`, `runs/*`: written by the
  retro role, read inside `<untrusted>` fences until promoted. A retro is a language
  model reading attacker-influenced text, and a one-issue injection must not become a
  permanent unfenced instruction for every later run.

The write path is a **pull request**: at retro, `advance` commits the proposed entries
on a branch of this repository and opens a PR that the owner merges — nothing lands on
the branch the dispatcher executes from without a human reading it. Retro never edits
an existing file; changes to curated memory are proposed in the post-mortem's "Proposed
for curated memory" section. When the PR cannot be opened, the patch is an artifact and
the retro comment says so. Details in `.claude/skills/swarm-memory/SKILL.md`.

## 10. Enforcement — what is real, and what is prose

The tool lists and the two PreToolUse hooks (`lib/hooks/`) are defence in depth. The
perimeter is:

- **The job token.** Read-class roles run with `github_token: ${{ github.token }}` in a
  job whose `permissions:` are `contents: read`, `issues: read`, `pull-requests: read`,
  `actions: read` — verified by the probe: a comment `POST` gets 403 and a push is
  refused by the remote. Write-class roles hold the Claude App's installation token,
  whose permissions bound the whole repository and cannot be narrowed per job.
- **Authoritative re-validation.** Whatever the role did to its workspace — the swarm's
  scripts (`chmod -R a-w .swarm` is friction, not a wall), the transcript,
  `validation.json`, `critic.json`, the handoff — is a claim. `advance` re-derives head,
  diff, ancestor, CI conclusion, PR base/draft state, repository activity and merger
  identity from GitHub and fresh checkouts, and only that verdict is recorded.
- **The signed state.** No job with a model step holds `SWARM_STATE_KEY` or
  `SWARM_TOKEN`; the swarm code reaches run jobs as an artifact, never a credentialed
  checkout; every project checkout uses `persist-credentials: false`. A forged state
  file fails its signature and blocks the issue.
- **Gate 3 is detective.** The App token may well be able to merge a PR or push a
  workflow file; the probe measures it once the stub is on the default branch, and until
  then the design assumes it can. So the merge that counts is checked for *who* merged,
  a `.github/**` change on a branch is `blocked:perimeter` with a `swarm:halt`
  recommendation, and `claude[bot]` activity outside the branch is caught by the
  Activity API (ls-remote snapshot as fallback).
- **Project configuration is restored, not trusted.** Headless runs load the checkout's
  `.claude/settings.json` hooks and `.mcp.json` as trusted configuration (probe R30:
  a planted SessionStart hook ran). `begin.sh` restores `.claude/`, `CLAUDE.md`,
  `.mcp.json` and `.claude-plugin/` from the branch's merge base with the default branch
  before any model runs; that restore is load-bearing.

Which job holds which secret: `resolve` and `advance` hold `SWARM_TOKEN` and
`SWARM_STATE_KEY` (plus the `refuse` job for the key); `run-read`, `run-write` and the
write-class `critic` job hold `CLAUDE_CODE_OAUTH_TOKEN` and nothing else. The residual,
accepted and written down: for the write class the transcript is role-writable, so a
"command was run" check is advisory there; for the read class `node`, `find` and
`npm run` are arbitrary execution inside a read-only job.

## 11. Token facts

- The App installation token is minted **per action step** by an OIDC exchange and
  revoked at the end of the step (`Revoke app token`, `if: always()`); no later step in
  the job can push as `claude[bot]`, so staged artifacts land *inside* the role's own
  push, and a retry step re-exchanges. The exchange only succeeds when the calling
  workflow file is identical on the default branch — a write-class stage cannot be
  exercised from a feature-branch stub.
- `github.token` fires no events except `workflow_dispatch` (and `pull_request`
  runs it creates sit in "approval required"). The dispatcher's comments and labels
  are therefore silent, its baton is `gh workflow run`, and **the PR is opened and every
  push to a branch with an open PR is made by a role** — never by the dispatcher.
- `github.token` commits through the Contents API carry author `github-actions[bot]`
  and a verified GitHub signature — which is exactly why author and signature are not
  the state file's trust anchor: any API writer gets them.
- `gh` infers the repository from the working tree; a job without a checkout must pass
  `-R <owner/repo>` to `gh workflow run`, `gh run list` and `gh run view`.
- Who pushed what is read from `GET repos/{o}/{r}/activity` (`actor.login`,
  `activity_type`, `ref`) — commit authors are forgeable, the actor is not.
