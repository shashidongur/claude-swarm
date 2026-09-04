# claude-swarm

A portable agent swarm that carries a GitHub issue from intake to a pull request you
merge. It lives in its own repository and is pointed at other projects; each project it
works on gets a memory folder here, where agents record how that codebase actually works
and how you want work done in it.

**Scope ends at your merge.** No deploy, no release, no production access.

Pipeline reference: https://claude.ai/code/artifact/50882bad-c8b8-4d8e-8cf9-f0f25b14ec11

---

## The pipeline

    Intake → Spec → Design → Build → Review → Test → Demo → PR → (you merge)

| Stage | Role | Passes when |
|---|---|---|
| Intake | `explorer`, or you | it names a defect or a capability |
| Spec | `product-owner` | at least one checkable assertion |
| Design | `designer` + `architect` | the contract is frozen before any code |
| Build | `implementer` + project specialists | compiles; existing tests still pass |
| Review | `reviewer` | no correctness or security finding |
| Test | `test-engineer` | a test was seen failing, **then** passing |
| Demo | `product-owner`, on a running app | every criterion demonstrated by clicking |
| PR | `implementer` | CI green; preview link in the body |

### Rework

Three loops send work backwards and share **one budget of five per issue**: Review and
Test return to **Build** (the code is wrong); Demo returns to **Spec** (the code is right
and the request was wrong). Your own change requests are **unlimited, never counted, and
reset the budget to five**. Budget spent → `swarm:blocked`, on your radar, never retried.

---

## Layout

    PLAYBOOK.md      operating policy — routines load this and abort without it
    lib/             prompt fragments composed into every role
    agents/          nine PORTABLE roles — no project specifics, ever
    skills/          swarm-tick (orchestrator), swarm-onboard, swarm-memory
    memory/github.com/<owner>/<repo>/    everything project-specific

**The split that makes this reusable:** `agents/test-engineer.md` says *prove the test
fails before you trust it*. A project's `gotchas/` says *the typecheck in this repo is a
false green because its config excludes the source directory*. Only the second changes
when you point the swarm somewhere else.

There is a test for this. It must stay clean:

    grep -rilE 'meipadam|tsconfig\.check|pglite|react-native|cdk' agents/ lib/ PLAYBOOK.md

---

## Onboarding a project

1. Run `swarm-onboard` against it. It explores, **runs** the checks rather than guessing
   at them, and writes `memory/github.com/<owner>/<repo>/`.
2. Read the memory it produced. Generic filler means the onboarding failed — fix it now,
   because every later run trusts this.
3. Open a pinned **Swarm Control** issue in the target repo. Its body carries runtime
   config; closing it is the kill switch.
4. Hand-run one small issue through every role locally before scheduling anything.

---

## How it loads

Cross-repository agent discovery does not exist: Claude Code finds agents in the project
`.claude/agents/`, the user directory, and plugins — and `additionalDirectories` grants
file access only. **Skills committed to a cloned repository do load**, so the entry point
is `skills/swarm-tick`, which reads role definitions from disk and passes them as
subagent prompts.

The consequence, stated plainly: **a role's `tools:` frontmatter is advisory.** The
enforced perimeter is the routine's own allowed-tools configuration. Do not treat the
role files as a security boundary.

Claude Code's own auto-memory does not survive a routine run — routines are stateless
cloud sessions and `~/.claude` dies with the container. That is why memory is git.

---

## Status

| | |
|---|---|
| Scaffolding | done |
| meipadam memory seeded | in progress |
| Hand-run of one issue | not yet |
| Spikes 1–4 | not yet |
| Routines enabled | not yet |

### Spikes to run before scheduling anything

Enough of the mechanism is undocumented that guessing would be expensive.

| # | Question | Fallback if it fails |
|---|---|---|
| 1 | Are both repos cloned, and at what paths? | clone this repo in-run with `gh repo clone` |
| 2 | Can a routine push to the **second** repo? | memory moves to a `swarm-memory` branch of each target |
| 3 | Do this repo's skills load in a routine? | inline the orchestrator into the routine prompt |
| 4 | Are `.claude/agents/` discovered cross-repo? | confirms read-as-text — assume this one fails |

Spike 2 is the one that can force a redesign.
