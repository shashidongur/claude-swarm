---
name: swarm-onboard
description: Bootstrap the memory folder for a project the swarm has never worked on. Run once per project, before any pipeline work.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

The swarm knows nothing about a project until this has run. Its output is the difference
between a portable role and a useful one.

Produce `memory/github.com/<owner>/<repo>/` with real, verified content. **Every command
you record must be run to confirm it works.** An onboarding that writes plausible
commands it never executed is worse than none, because every later run will trust them.

## 1. conventions.md — the load-bearing one

Establish and **verify by running**:

- the real typecheck, lint, test, and build commands, per package if the repo has more
  than one
- **whether each check actually covers the code under change.** Run the typecheck, then
  deliberately introduce a type error in a source file and confirm the check catches it.
  A configuration that excludes the source directory produces a green run that means
  nothing, and this is common enough to be worth the two minutes.
- where tests live and how they are named
- branch and pull request naming already in use — read the last twenty of each
- how a change reaches a running application: is there a dev server, a preview build,
  seed data, a way to sign in as each role? This is what the demo stage depends on. If
  no runnable preview exists, **say so explicitly** — the demo cannot run until one does,
  and pretending otherwise breaks the pipeline silently.
- any hand-mirrored contract: a type declared in two places that must move together
- the requirements document and coverage log, if they exist

## 2. gotchas/

Mine, in this order: the project's instructions file, comments that explain *why*, test
files with unusually long doc comments, and commit messages describing a fix that was
not obvious. A gotcha is something that cost someone time and is not visible from the
code alone.

## 3. agents/ — this project's specialists

Where the codebase has distinct halves with different invariants — a server and a client,
two languages, two deployment targets — write a specialist role for each, layered on the
portable `implementer`. Give it only what is specific to this project. Anything true of
implementers everywhere belongs in the portable role, not here.

## 4. preferences.md

Start it, even nearly empty. Seed it only from things the owner has actually said or
written, never from inference. It fills in over time; that is the point.

## 5. MEMORY.md

The index. One line per memory.

## Finally

Report what you could not determine. An honest gap is actionable; a confident guess is a
defect that surfaces three stages later, in a role that has no reason to doubt it.
