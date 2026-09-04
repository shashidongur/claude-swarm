---
name: resize-a-mounted-tree-in-jest
description: "Dimensions.set() fires a real 'change' event in jest, so a mounted RN tree can be resized; and toJSON() trees are circular"
metadata:
  type: gotcha
---

`Dimensions.set({window, screen})` is the entry point React Native's own
`didUpdateDimensions` listener calls, and it emits `'change'` on the module's
event emitter. The jest RN preset only mocks the *native constant*
(`DeviceInfo.getConstants`), not the module, so calling `set()` inside `act()`
delivers a real resize to a tree that is already mounted — `useWindowDimensions`
consumers update. That is what makes split-screen / fold transitions testable as
a **transition** rather than as two separate mounts.

Spying on `Dimensions.get` (what `deviceHarness.applyDevice` does) does *not*
fire the event; both are needed. `mobile/src/testing/multiWindow.ts` wraps the
pair as `resizeTo(device)`.

Two traps:
- Comparing trees with `JSON.stringify(view.toJSON())` throws "Converting
  circular structure to JSON" — a `ScrollView`'s `refreshControl` prop is a React
  element holding its fiber. Strip elements with a replacer, but keep the tree's
  own nodes: they are tagged `Symbol.for('react.test.json')`, so a naive
  `'$$typeof' in value` check collapses the whole tree to one string and the
  assertion passes for the wrong reason.
- A split window makes `Dimensions.get('screen')` differ from `('window')` for
  the first time in this repo's matrix; `Device.screen` carries it.

Related: [[mobile-device-matrix-harness]], [[jest-tz-switching-is-inert]],
[[js-default-locale-is-immutable]].
