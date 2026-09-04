---
name: actions-dispatch-gotchas
description: Traps in the GitHub Actions half of the swarm — bash -e aborts guards, and event payloads reach Actions but never routines
metadata:
  type: gotcha
---

## `run:` steps are `bash -eo pipefail`, and guards look like failures

GitHub runs every `run:` block under `bash --noprofile --norc -eo pipefail`. A dispatch
guard written the natural way —

    jq -e 'any(. == "swarm:hands-off")' labels.json && say "hands-off"

— **aborts the step** when `jq -e` returns false, which is the *normal* path. The step
goes red, and a correctly-refused dispatch becomes indistinguishable from a broken
workflow.

**How to apply:** start the guard step with `set +e`, and write every guard as an
explicit `if … then … fi`. Reserve `|| say …` for command-substitution failures, where
non-zero genuinely means the command failed.

## Only Actions receive the event; routines never do

`issue_comment` is not a supported cloud-routine trigger — only Pull request and Release
— and even those deliver **no payload into the routine's prompt**. A PR-triggered routine
cannot see which PR fired it. Anything that has to know *what happened* must run in
Actions.

The corollary: the swarm is split by the nature of its trigger, not by preference.
Event-driven pipeline → Actions. Time-driven sweeps with nothing to react to → routines.

## The mention prefix must be checked against real accounts

GitHub linkifies `@handle`. An unprefixed `@reviewer` would notify whoever owns that
account on every single handoff. Prefix per project (`@<project>-swarm-<role>`) and
confirm each handle 404s before the first run — see `lib/ROUTING.md`.

## `.github/workflows/**` is on the never-write list, deliberately

The playbook forbids agents from editing workflows, because a swarm that can rewrite its
own gates has no gates. The dispatch workflow was therefore authored under direct
instruction and landed through a reviewed pull request — which is the only way it should
ever change.
