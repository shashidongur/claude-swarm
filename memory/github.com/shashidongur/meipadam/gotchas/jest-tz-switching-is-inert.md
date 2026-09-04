---
name: jest-tz-switching-is-inert
description: Setting process.env.TZ inside jest does not move Date — build a zone axis from explicitly-zoned Intl plus an instant shift instead
metadata:
  type: gotcha
---

Assigning `process.env.TZ` at runtime moves `Date` in plain `node -e`, and does
**nothing** inside jest: `jest-environment-node` gives the test context its own
copy of `process`, so the assignment never reaches the Node setter that flushes
V8's date cache. A zone sweep written that way passes while measuring the
runner's own zone N times — i.e. it fails in the direction that reports no defect.

**Why:** the helper looks correct when you try it outside the runner, so the trap
is expensive; and a vacuous zone comparison is green.

**How to apply:** `mobile/src/testing/zones.ts` is the working shape —
`Intl.DateTimeFormat(..., { timeZone })` for calendar questions (it takes the
zone as an argument), and `asIfInZone(iso, tz)` for render questions (shift the
*instant* so the runner's local clock reads the target zone's clock; exact for
anything reading only local getters, which is all of `utils/datetime.ts`).
`mobile/src/testing/__tests__/zoneControl.test.ts` pins the negative result as
its first test. Related: [[mobile-device-matrix-harness]].
