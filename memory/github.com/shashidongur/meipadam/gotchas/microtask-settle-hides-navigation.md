---
name: microtask-settle-hides-navigation
description: Settling a jest RN test with Promise.resolve() reads the tree a frame early — it hid a real React Navigation behaviour and made an it.failing pin confirm itself
metadata:
  type: gotcha
---

In `mobile/src/screens/__tests__/*.flow.test.tsx`, settle with **macrotask** turns
(`await act(async () => { await new Promise(r => setTimeout(r, 0)) })`), never with
`await act(async () => { await Promise.resolve() })`.

**Why:** react-query's `notifyManager` batches through `setTimeout(0)`, and React
Navigation defers work through `requestAnimationFrame`. A microtask loop returns
before either lands. This is not academic: `NavigationGraph.flow.test.tsx` recorded
"pressing the parked Home tab is inert" as a confirmed defect (finding 101) for
eighteen iterations. It is false — `createNativeStackNavigator` registers its own
`tabPress` listener on the parent tab navigator and dispatches
`StackActions.popToTop()` inside a `requestAnimationFrame`, and the event it hears
is the one `CustomTabBar` emits *before* its `if (!isFocused)` early return. The
pin read the un-popped tree and passed for the wrong reason.

**How to apply:** when a flow test presses a control and asserts on the tree,
settle over macrotasks and give it one turn per leg of the request waterfall. If a
suite intermittently fails only under a full parallel run, suspect the settle
before suspecting the app. Related: [[react-query-settle-in-jest]],
[[render-real-navigator-in-jest]], [[mobile-jest-hangs-after-pass]].
