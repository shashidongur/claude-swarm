---
name: preferences
description: How the owner wants work done in this repo — seeded from what they have actually said
metadata:
  type: preference
---

Seeded from the owner's stated instructions and this repo's own history. Only add
entries from things they actually said or wrote — never from inference.

## A test that cannot fail is not evidence

Before trusting a new test, confirm it fails against the unfixed code, and say that you
did. **Why:** a suite that goes green against unfixed code proves the suite runs, not
that the code works. **How to apply:** capture both runs — pre-fix failing, post-fix
passing — and paste both into the PR body. This repo already practises it: 26 of its 38
issue-regression files use `it.failing` blocks as executable defect pins, and the fix is
done when they become plain `it`.

## Distrust a green check until you know what it covers

**Why:** a passing `tsc --noEmit` or test run has burned the owner before when the
config quietly excluded the files under change. **How to apply:** verify scope before
reporting green. In this repo specifically, see [[backend-typecheck-gap]].

## Report the outcome, and what was actually checked

One line naming the verification — the command run, the test that passed, the file read.
Say what was *not* checked just as plainly. **Why:** a claim labelled unverified is
useful; the same claim presented as fact is not. **How to apply:** never let a summary
imply more verification than was performed.

## Lead with the answer, then structure

Bold the answer first, then headers, bullets, and tables. Use a table whenever three or
more things are compared across the same dimensions. Skip preamble. Cite code as
`file.ts:42`. **Why:** the owner scans rather than reads.

## Judge by reversibility

Easily undone — make the call, state the assumption in one line, keep going. Hard to
reverse, outward-facing, or expensive — stop and ask.

## No step-by-step narration by default

Report what happened and what it means, not a trail of every step. The trail is
available on request.
