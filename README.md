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

    PLAYBOOK.md          operating policy — routines load this and abort without it
    lib/                 prompt fragments composed into every role
    .claude/agents/      nine PORTABLE roles — no project specifics, ever
    .claude/skills/      swarm-tick (orchestrator), swarm-onboard, swarm-memory
    memory/github.com/<owner>/<repo>/    everything project-specific

**The `.claude/` prefix is not cosmetic.** Spikes 3 and 4 put an identical probe in both
`skills/` and `.claude/skills/`, and in both `agents/` and `.claude/agents/`. Only the
`.claude/` ones were found; the root-level ones returned *"Unknown skill"* and
*"Agent type not found"* despite being present on disk. The plugin layout is read only
when a plugin is installed, which a routine does not do — and a role in the wrong
directory does not error, it simply is not there.

**The split that makes this reusable:** `.claude/agents/test-engineer.md` says *prove the
test fails before you trust it*. A project's `gotchas/` says *the typecheck in this repo
is a false green because its config excludes the source directory*. Only the second
changes when you point the swarm somewhere else.

There is a test for this. It must stay clean:

    grep -rilE 'meipadam|tsconfig\.check|pglite|react-native|cdk' .claude/agents/ lib/ PLAYBOOK.md

## Onboarding a project

**The project's half is one file, and it is a stub.** GitHub only runs workflows that
live in the repository receiving the event, so every project needs *a* dispatch workflow —
but not *this* one. Copy `templates/swarm-dispatch.yml`, change `mention_prefix`, and the
260 lines of guards stay here, called once.

That matters because those guards have already needed six corrections. Copied per
project, that would have been six corrections times the number of projects, discovered
one silent stall at a time.



1. Run `swarm-onboard` against it. It explores, **runs** the checks rather than guessing
   at them, and writes `memory/github.com/<owner>/<repo>/`.
2. Read the memory it produced. Generic filler means the onboarding failed — fix it now,
   because every later run trusts this.
3. Open a pinned **Swarm Control** issue in the target repo. Its body carries runtime
   config; closing it is the kill switch.
4. Hand-run one small issue through every role locally before scheduling anything.

---

## How it loads — measured, not assumed

A routine clones this repo alongside the target and **discovers both its skills and its
agents** from `.claude/`. Roles are spawned by name, so their `tools:` lists are enforced
by the harness. Verified by spikes 3 and 4 rather than inferred; see issue #1.

Two facts that cost nothing to know and a lot to discover late:

- Root-level `agents/` and `skills/` are **not** discovered. Only `.claude/`.
- **`gh` is not on PATH** in a routine. GitHub work goes through the GitHub MCP tools.

Claude Code's own auto-memory does not survive a routine run — routines are stateless
cloud sessions and `~/.claude` dies with the container. That is why memory is git, and
why spike 2 mattered: a routine **can** push to the second repo, so learning pools here
rather than scattering across targets.

## Status

| | |
|---|---|
| Scaffolding | done |
| meipadam memory seeded | done — 27 gotchas |
| Spikes 1–4 | **done** — all four answered, see issue #1 |
| Hand-run of one issue | done — meipadam#44, spec → demo, zero rework rounds |
| Routines enabled | not yet |

### What the spikes settled

| # | Question | Answer |
|---|---|---|
| 1 | Workspace layout | Both repos cloned side by side under `/home/user/` |
| 2 | Cross-repo push | **Works** — memory pools in this repo as designed |
| 3 | Skill discovery | `.claude/skills/` only |
| 4 | Agent discovery | `.claude/agents/` only — and it **works cross-repo**, so tool restrictions are enforced |
