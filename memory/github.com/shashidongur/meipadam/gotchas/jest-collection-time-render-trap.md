---
name: jest-collection-time-render-trap
description: "In device sweeps, code choosing between it/it.failing runs at jest collection time, before beforeEach stocks hook mocks — so it cannot render"
metadata:
  type: gotcha
---

Anything inside a `describe.each` / `describeEachDevice` body that runs *outside*
an `it()` executes while jest is collecting tests — before any `beforeEach` has
run. In `mobile/src/screens/__tests__/*.devices.test.tsx` that means the
`useAuth`/`useMyMembership` mocks are still empty, so rendering there throws
`Cannot read properties of undefined (reading 'user')` and the whole suite fails
to run.

This bites exactly where the [[mobile-device-matrix-harness]] pattern needs it:
picking `fits ? it : it.failing` per device requires the measurement *before* the
test body.

**Why:** the per-device predicate is what keeps a sweep both green and truthful —
a blanket `it.failing` turns red on the canvases where a control genuinely clears
its minimum.

**How to apply:** model the predicate from constants (declared paddings, font
sizes, `device.width`/`insets`), and add one ordinary `it()` that renders once and
asserts those constants against the rendered styles. The model stays honest, and
a padding change fails that test instead of drifting silently.
