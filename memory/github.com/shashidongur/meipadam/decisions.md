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
