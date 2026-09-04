---
name: mobile-engineer
description: meipadam's client-side specialist. Layers on the portable implementer with this app's invariants.
metadata:
  type: convention
---

Follow `agents/implementer.md` first. This adds what is true only here.

## Non-negotiables

- **Theme tokens only.** `colors`, `spacing`, `radius`, `shadow`, `typography` from
  `mobile/src/theme/`, and primitives from `components/ui/`. A raw hex value fails the
  contrast harness, which composites WCAG ratios off the rendered tree.
- **`mobile/src/types/*` mirrors `backend/src/dto/*` by hand.** No codegen. Both sides
  move in the same commit or the mismatch surfaces at runtime as a comparison that
  quietly stops matching.
- **Every mutation hook invalidates every query key whose data it invalidates.** This is
  the single most common defect class in this app — a grant that leaves a search list
  stale, a save that snaps back because the cache had not refetched.
- **`tabBarClearance`** is bottom padding so scroll content clears the floating tab bar.
  Device tests assert it; omitting it hides content behind the bar on short canvases.

## Test traps — read before writing a test

- JSX tests must be `.tsx`. [[test-utils-navigation-mock-trap]] — importing `test-utils`
  before the screen silently overrides the file's own navigation mock.
- [[mock-return-value-freezes-effect-deps]] — `useMutation` returns a fresh object per
  render; `mockReturnValue` freezes it and the bug disappears.
- [[react-query-settle-in-jest]] and [[microtask-settle-hides-navigation]] — settling
  needs one `act()` per macrotask turn, and `Promise.resolve()` loops read the tree a
  frame early.
- [[jest-mock-factory-and-timer-traps]], [[mobile-jest-hangs-after-pass]] — use
  `--forceExit` while iterating; the open handle is pre-existing.
- [[mobile-device-matrix-harness]] — `mobile/src/testing/` renders screens at real
  device canvases. Use it when layout could branch on width.

## What the harness cannot see

`react-test-renderer` runs no layout pass. The device matrix catches canvas-*decided*
bugs — throws, branches on width, stale module-scope dimensions, self-computed size math
— not measured overflow. Nothing here has ever run on a simulator or a device.
