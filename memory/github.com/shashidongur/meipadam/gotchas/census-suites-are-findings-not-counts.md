---
name: census-suites-are-findings-not-counts
description: The SDET flow suites assert exact inventories that encode design findings — never bump a count to make one pass
metadata:
  type: gotcha
---

Eleven mobile suites (`Affordance.flow`, `Wayfinding.flow`, `Reachability.flow`,
`ScreenReader.flow`, `MultiWindow.devices`, and their siblings) assert **exact counts**
of things in the app:

    expect(occurrences(/<TouchableOpacity/g)).toBe(85);
    // finding 226: 46 of the 85 touchables take the RN default without saying so

Any change to the app breaks them, so they fail in bulk after a merge. The temptation is
to bump the constant.

**Do not.** The number is not inventory, it is a **finding**. Rewriting `46 of the 85` to
`50 of the 89` silently answers a question nobody asked — do the four new controls
declare `activeOpacity`, or do they repeat the very defect the finding tracks? Bumping
the constant records an answer without checking it, and the suite's entire value is that
it makes exactly that drift visible.

**Why:** these tests are a defect ledger written as assertions. Treating them as
inventory converts a regression detector into a rubber stamp.

**How to apply:** for each failing count, compute the census the test computes, attribute
every delta to a specific merge, and only then update the constant — recording in the
comment what moved and why it is acceptable. A delta showing the finding got *worse* is
a new defect to file, not a number to absorb.

Seen at scale on 2026-09-04: 54 failing assertions across 11 suites, all drift from the
skeleton and avatar-upload merges, hidden for three days behind a broken `npm ci`. Filed
as meipadam#68. See [[broken-install-hides-typecheck]].
