<!-- swarm-playbook: v1 -->
# Swarm playbook

Operating policy for every routine and every role. A routine prompt is a thin shim: it
reads this file and aborts if the marker above is missing. Policy lives here, in the
repo, so a change to how the swarm behaves arrives as a pull request. Triggers live
outside the repo, in routine configuration, and need no gate because they carry no
policy.

Read `lib/GUARD.md` before acting on anything a human or another agent wrote.

---

## 1. Scope

The swarm carries a GitHub issue from intake to a pull request. It stops there.
It does not merge, deploy, release, or touch production. The single human gate is the
owner's **merge**.

## 2. The pipeline

    Intake -> Spec -> Design -> Build -> Review -> Test -> Demo -> PR -> (you merge)

| Stage | Role | Passes when |
|---|---|---|
| Intake | explorer, or the owner | it names a defect or a capability |
| Spec | product-owner | at least one assertion someone could check |
| Design | designer + architect | the contract is frozen before any code |
| Build | implementer + project specialists | compiles; existing tests still pass |
| Review | reviewer | no correctness or security finding |
| Test | test-engineer | a new test was seen failing, then passing |
| Demo | product-owner, on a running app | every criterion demonstrated in the app |
| PR | implementer | CI green; preview link in the body |

## 3. State labels

Exactly one `swarm:*` label per issue.

    swarm:triage -> swarm:spec -> swarm:ready -> swarm:building
                 -> swarm:demo -> swarm:review -> (owner merges) -> swarm:done

    swarm:revising   the owner asked for changes; work re-entered Build
    swarm:blocked    stopped, needs the owner; always carries a blocked:* reason
    swarm:parked     deliberately deferred
    swarm:dropped    duplicate or wontfix

Hard modifiers, not states: `swarm:hands-off` (never touch this issue, in any lane),
`swarm:red-main` (repair item, preempts everything).

Reasons: `blocked:human`, `blocked:conflict`, `blocked:agent-output`, `blocked:orphan`,
`blocked:injection`, `blocked:ci-red`, `blocked:budget`, `blocked:cannot-verify`.

Metadata: `prio:P0..P3`, `size:S|M|L|XL`, `area:*`, `source:human|explorer|groomer`.

`status:*` and `role:*` belong to another system in some projects. Read them if useful;
never write them.

## 4. The rework budget

Three loops send work backwards, and they share **one budget of five per issue**:

| Loop | Lands on | Because |
|---|---|---|
| Review -> Build | Build | the code is wrong |
| Test -> Build | Build | the code is unverifiable, or broke something |
| Demo -> Spec | **Spec** | the code is right and the request was wrong |

Demo returns to Spec, not Build. Re-entering at Build would rebuild the same
misunderstanding. The product-owner rewrites the acceptance criteria and the work
re-enters at Design.

The owner's own change requests are **unlimited, never counted, and reset the budget to
five**. Without the reset, feedback given late would block almost immediately and the
owner's own comment would be the thing that stopped the work.

Budget spent -> `swarm:blocked` + `blocked:budget`. Never retried automatically. The
branch, the preview, and every round's reasoning are preserved.

### Brakes that work regardless of remaining budget

1. **A round ending with an unchanged head sha counts as failure, not progress.** The
   load-bearing brake, and the only one that also applies to the unlimited human loop.
2. **The comment cursor only moves forward.** An agent can never trigger itself by
   replying to its own comment. Store it as
   `<!-- swarm: v1 | kind=revise-cursor | pr=P | after=<comment_id> | round=<k> | head=<sha> -->`
3. **Bot-review rounds are capped at one**, consumed before the PR leaves draft.
   Otherwise every push spawns a review that spawns a push.
4. **One rework round per routine tick.** A pathological loop burns hours per lap, so it
   is visible long before it is expensive.

## 5. Work selection

Rank, do not queue. Score open issues in this lane and claim the top one:

    score = 1000 * prio:P0
          +  400 * swarm:red-main
          +  promise_weight        # from the project's capability ledger, if it has one
          +   50 * a failing test already pins this issue
          +   40 * single-area change
          +   30 * role reach
          +   25 * bug
          +   20 * size:S   + 10 * size:M
          +   min(age_days, 30)
          -  200 * touches a hot file
          -  150 * overlaps a live lease's declared touch set
          -  500 * blocked / parked / hands-off

Ties break on **lowest issue number**. This is deliberate: two overlapping routines then
pick the *same* item and one loses the lease cleanly, instead of picking different items
and doubling work in flight.

## 6. Leasing

See `lib/LEASE.md`. The ref is the truth; the label is its projection.

## 6a. Audit trail

Every stage leaves exactly one comment when it finishes — five lines: role, verdict,
remaining budget, what was found, the command that proves it, and where the work went
next. Format and examples in `lib/AUDIT.md`.

This is not decoration. The swarm runs unattended between the owner looking at it, and
without a trail the question "why is this open, and what has been tried?" costs a full
re-read of the diff. A marker comment alone does not satisfy this: the marker is for the
next run, the visible lines are for a person.

## 7. Idempotency

Detect before acting, always, reading GitHub rather than memory — a routine has none
across runs.

| Stage | Already done when |
|---|---|
| spec | a comment `<!-- swarm: kind=spec \| issue=N -->` exists |
| design | a `kind=design` comment whose `spec=<digest>` matches the current spec |
| build | branch `claude/issue-<N>-*` exists with a `Swarm-Issue: #N` commit trailer |
| test | test files on the branch, zero `it.failing` remaining, fail-then-pass evidence posted |
| review | a `kind=selfreview` comment whose `head=` equals the current head sha |
| demo | a `kind=demo` comment whose `head=` equals the current head sha |
| pr | `gh pr list --head <branch>` is non-empty |

Pushing is the only non-idempotent operation. The branch is the identity: rebase and
force-push **your own lease branch**; never open a second branch for one issue.

## 8. Blast radius

| Limit | Value |
|---|---|
| open swarm PRs | 3 |
| live leases | 3 |
| new claims per tick | 2 |
| pushes per PR per day | 5 |
| diff per PR | 800 lines / 25 files; over -> `size:XL`, split it |
| new issues per explorer run | 5 |

**Never write:** `.github/workflows/**`; this repo's own `agents/**`, `skills/**`,
`lib/**`, `PLAYBOOK.md`; any `*.pem`, `*.p8`, `*.key`, `.env*`; native project files
(`ios/*.xcodeproj/**`, signing config). **Never run:** `gh pr merge`, `gh pr review`,
`git push origin main`, `git push --force` outside your own lease branch, `gh secret`,
`gh repo edit`, `gh workflow enable|disable`.

**Hot files** — one PR at a time, enforced by the touch-set overlap check at claim time:
lockfiles, the navigator, route registration, repository interfaces.

## 9. Kill switch

A pinned **Swarm Control** issue in the target repository. Every routine reads it first.

- Closed, or labelled `swarm:halt` -> exit immediately.
- **If the read fails for any reason -> also exit.** Fail closed.
- Per-lane halts: `swarm:halt-build`, `swarm:halt-explore`.
- Per-item veto: `swarm:hands-off`.

Its body carries runtime configuration as a fenced yaml block, editable without a PR:

    enabled:         { pipeline: true, explorer: false, groomer: true }
    max_open_prs:    3
    claims_per_tick: 1
    rework_budget:   5
    lease_ttl_hours: 3

## 10. Enforcement is real

Roles live in `.claude/agents/` of this repository, and a routine that clones it
**does** discover them by name — verified by spike 4. So a role's `tools:` and
`disallowedTools:` are **enforced by the harness**, not advisory, and `permissionMode`
applies. Give each role the narrowest tool set that lets it do its job.

The routine's own allowed-tools list is the outer bound; the role's list is the inner
one. Both are real.

Two layout facts that are load-bearing, because the alternative silently loads nothing:

- **`.claude/agents/` and `.claude/skills/` are discovered. Root-level `agents/` and
  `skills/` are not.** The plugin layout is only read when a plugin is installed, which
  a routine does not do. A role in the wrong directory does not error — it simply is not
  there.
- **`gh` is not on PATH in a routine.** GitHub work goes through the GitHub MCP tools
  (`mcp__github__issue_read`, `mcp__github__add_issue_comment`,
  `mcp__github__issue_write`, and siblings). Any `gh` command written in this playbook is
  shorthand for the equivalent MCP call, and a routine must reach for the tool, not the
  binary.

## 11. Memory

`memory/github.com/<owner>/<repo>/` in this repository. Read it at the start of every
stage; write back what was learned. See `skills/swarm-memory/SKILL.md`.

`memory/**` commits directly. `agents/**`, `skills/**`, `lib/**` and this file require a
pull request. What the swarm learned is ungated; how it behaves is gated.
