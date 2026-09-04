---
name: validate-tests-against-main
description: Regression suites written on a long-lived branch must be re-run against main before landing — the branch is 26 commits behind
metadata:
  type: gotcha
---

The `issueNN-*` regression suites were authored on a testing branch that diverged from
`main` on 2026-08-21. Landing them without re-running them against `main` produces two
silent failure modes:

1. An `it.failing` pin whose defect was **fixed on main** reports *"Failing test passed
   even though it was supposed to fail"* — a red suite that actually means good news.
2. A plain `it` written against the old behaviour fails because `main` changed the
   endpoint under it, which reads as a broken test rather than as the regression it is.

Both happened. See [[decisions]].

**Why:** a test is evidence only about the tree it ran against.

**How to apply:** copy the suites into a worktree checked out at `origin/main`, symlink
`node_modules`, run them, and classify every failure as *fixed*, *regressed*, or *stale*
before landing anything. `npx jest __tests__/issue` takes about 45 seconds for the
backend set.
