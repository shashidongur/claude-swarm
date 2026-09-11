---
name: swarm-onboard
description: Bootstrap a project the swarm has never worked on — its memory folder and its .github/swarm.yml, plus the labels, the state branch, the secrets and the repository settings the v2 pipeline needs. Run once per project, by a human, before any pipeline work.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

The swarm knows nothing about a project until this has run. Its output is the difference
between a portable role and a useful one — and in v2 it is also the configuration the
dispatcher reads on every event.

Produce two things with real, verified content: `memory/github.com/<owner>/<repo>/` in
this repository, and `.github/swarm.yml` in the project. **Every command you record must
be run to confirm it works.** An onboarding that writes plausible commands it never
executed is worse than none, because every later run will trust them — the dev brief
quotes the lane's commands verbatim.

## 1. conventions.md — the load-bearing one

Establish and **verify by running**:

- the real install, typecheck, lint and test commands, per package if the repo has more
  than one; note where the names differ between packages
- **whether each check actually covers the code under change.** Run the typecheck, then
  deliberately introduce a type error in a source file and confirm the check catches it.
  A configuration that excludes the source directory produces a green run that means
  nothing, and this is common enough to be worth the two minutes.
- where tests live and how they are named; how a red test is pinned before a fix (the
  `pin_marker`)
- branch and pull request naming already in use — read the last twenty of each
- any hand-mirrored contract: a type declared in two places that must move together
- the requirements document, its id pattern, and the coverage log, if they exist
- what CI runs today, what is red on the default branch today (test failures, audit
  advisories, SAST findings) — those become the baselines, not the dev's rework

## 2. `.github/swarm.yml` — generated from what you verified

Start from `templates/swarm.yml` (every key commented, one `CHANGE-ME` lane). Fill in:

- `lanes` — one per top-level directory with its own lockfile, **in the order work
  should happen** (the plan's "server first" is this order); per lane `paths`, the
  specialist file from step 4, and `commands` (`cwd`, `install`, `typecheck`, `test`,
  `lint`) exactly as run in step 1
- `test_paths` — where the test-writer may write; `pin_marker`;
  `requirements_doc` and `requirement_id_pattern`
- `sensitive_paths` — auth, payments, personal data, analytics: compliance runs on the
  short path only when these are touched
- `protected_paths` — anything owned by another workflow, generated trees, and **the
  CI gate's own files**: test baselines, coverage-check scripts, audit baselines,
  scanner allow-lists, `**/<test runner>.config.*`; `gate_manifests` = the package
  manifests whose `test:ci`/`lint`/`typecheck` scripts must not change on a branch
- `evidence` — the CI workflow's `name:`, and the optional `test` and `security`
  workflows once they exist (`lib/EVIDENCE.md` is their contract; `walkthrough_when`
  narrows the device walkthrough to the client lane)
- `approvers` — on an organisation-owned repository this is mandatory; on a user-owned
  one the owner is the default. Verify with `gh api users/<owner> --jq .type` and
  record the answer in `conventions.md`.
- `limits` and `watchdog` — only to lower a default

Validate: `lib/sh/config.sh` against the file must succeed with no warnings you cannot
explain.

## 3. gotchas/

Mine, in this order: the project's instructions file, comments that explain *why*, test
files with unusually long doc comments, and commit messages describing a fix that was
not obvious. A gotcha is something that cost someone time and is not visible from the
code alone. One file each under `gotchas/`, one line each in `gotchas/INDEX.md`.

## 4. agents/ — this project's specialists

Where the codebase has distinct halves with different invariants — a server and a
client, two languages, two deployment targets — write a specialist role for each,
layered on the portable `dev`, and name it in the lane's `specialist:` key. Give it
only what is specific to this project. Anything true of developers everywhere belongs
in the portable role, not here.

## 5. preferences.md and decisions.md

Start both, even nearly empty. Seed preferences only from things the owner has actually
said or written, never from inference. Record in decisions the choices already visible
in the repository's history so no run relitigates them.

## 6. MEMORY.md and the indexes

`MEMORY.md` ≤ 40 lines: pointers to `conventions.md`, `preferences.md`,
`decisions.md`, the specialists, `gotchas/INDEX.md`, `adrs/INDEX.md`,
`postmortems/INDEX.md`. Create `gotchas/auto/.gitkeep`, `adrs/INDEX.md`,
`postmortems/INDEX.md`, `runs/.gitkeep`. `lib/sh/memory-index.sh` regenerates the
indexes.

## 7. The project's side — run these, in this order

1. `lib/sh/labels.sh install <owner/repo>` — idempotent; creates the `swarm:*`,
   `blocked:*`, size/area/prio labels (`area:*` from the lanes you configured)
2. `lib/sh/state.sh init-branch <owner/repo>` — the orphan `swarm/state` branch
   (422 = already exists, fine)
3. `gh secret set SWARM_STATE_KEY --repo <owner/repo> --body "$(openssl rand -hex 32)"` —
   the state file's signing key; never printed, never in a job with a model
4. `SWARM_TOKEN` — a fine-grained PAT on **this** repository (Contents: read and
   write, Pull requests: read and write; optionally the account permission Plan: read so
   the monthly brake can read billing); `CLAUDE_CODE_OAUTH_TOKEN` from
   `claude setup-token`
5. *Settings → Actions → Workflow permissions* → "Read repository contents and packages
   permissions" — a project workflow must never hold a write token by omission
6. Copy `templates/swarm-dispatch.yml` to `.github/workflows/swarm-dispatch.yml` with
   `workflow_run.workflows` set to the evidence names; list the evidence workflows that
   exist and note the ones still to be written
7. Record the baselines the CI gates compare against (the test runner's failing set in
   the exact mode CI runs, the coverage percentages under the shipped config, the audit
   advisories on the default branch) and scan the full history for secrets once — a
   secret scan is never baselined
8. **Run the probe** — copy `templates/swarm-probe.yml`, run it, write the answers into
   `memory/_swarm-itself/v2-probe-results.md`, delete it. Write-class questions (what
   the App token can reach) only answer once the stub is on the default branch.
9. Open the pinned Swarm Control issue (kill switch; no config in its body)

## Finally

Report what you could not determine. An honest gap is actionable; a confident guess is a
defect that surfaces three stages later, in a role that has no reason to doubt it.
