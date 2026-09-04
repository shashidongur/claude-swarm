---
name: crawl-the-navigator-in-jest
description: "How to breadth-first crawl the app's real navigator in jest, and the two ways a crawler lies"
metadata:
  type: gotcha
---

`mobile/src/testing/navGraph.ts` crawls the real `RootNavigator` under jest: press
every control on every reachable screen, record the route each press lands on.
Two things it took a fixture to get right (`src/testing/__tests__/navGraphControl.test.ts`):

- **One fresh mount per press.** Pressing a control changes the tree, so the
  second control on a screen cannot be pressed after the first — the crawler
  re-mounts and replays the shortest known path before every press (72 mounts,
  ~6s, for the student surface). This is also what makes each edge independent
  of the edge measured before it.
- **Verify the control at press time, not just the replayed path.** If the list
  on this mount differs from the list that was enumerated, pressing index `i`
  presses something else and records an *invented* edge — worse than a missing
  one, because nothing about it looks wrong. Both checks report into
  `graph.unstable` instead of pressing.

Enumerate controls **per route through a route→component map**, not by walking the
whole tree: a bottom-tab navigator keeps every visited tab mounted, and a
root-stack screen sits above a still-mounted `CustomTabBar`, so a tree-wide
touchable walk returns the controls of three screens the student is not looking at.

Related: [[render-real-navigator-in-jest]], [[affordance-harness]],
[[microtask-settle-hides-navigation]], [[react-query-settle-in-jest]].
