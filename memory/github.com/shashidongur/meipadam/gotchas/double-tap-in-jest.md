---
name: double-tap-in-jest
description: Model a real double tap by firing two fireEvent.press inside ONE act; React Navigation applies the second action to the state the first produced
metadata:
  type: gotcha
---

Two `fireEvent.press(el)` calls inside a single `act()` model a real double tap
(the outgoing native-stack screen stays interactive during its dismissal
animation, and a `disabled` prop set by the first press is not on the element the
second press hits). Two presses in *separate* `act()`s model a deliberate second
tap seconds later, which is what an `isPending` guard blocks.

**Why:** React Navigation dispatches through a functional `setState`, so the
second action is applied to the state the first produced — two `goBack()`s pop
two screens, while two `navigate()`s to the same route+params collapse to one
(StackRouter matches a `NAVIGATE` against the *current* route by name unless the
route declares `getId`).

**How to apply:** read the resulting route off the container ref
(`getRootState().routes`), not off rendered text — see
[[android-back-button-in-jest]]. Same harness as
[[render-real-navigator-in-jest]]; settle react-query with
[[react-query-settle-in-jest]].
