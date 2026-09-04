---
name: affordance-harness
description: mobile/src/testing/affordance.ts reads which pixels look pressable; two react-test-renderer traps shaped it
metadata:
  type: gotcha
---

`mobile/src/testing/affordance.ts` (added iteration 29) reads *declared*
affordance off a rendered tree: `controls(root)` (text, glyphs, painted surface,
disabled, effective `activeOpacity` with RN's silent `?? 0.2` filled in),
`textRuns(root)` (style + whether a touchable is above it), `effectiveOpacity`,
`typeSignature`. Asserted in `src/testing/__tests__/affordanceControl.test.tsx`
before findings lean on it, same discipline as [[jest-tz-switching-is-inert]].

**Why:** `TouchableOpacity` paints nothing of its own — no tint, ripple, border
or focus ring — so every "this is a button" signal is a style the app declared,
which makes "does anything look pressable" a diff over declared style rather
than an opinion.

**How to apply:**
- A react-test-renderer `.parent` chain carries the composite *and* its host
  element, each appearing twice, so one declared `opacity: 0.55` shows up five
  times up one chain. Walk **host nodes only, deduped by `props` identity** —
  naive multiplication reports 0.09 for a 0.55. A touchable's own declared
  opacity lives on the composite, so multiply it in separately.
- Picking "the control's painted surface" must match on `backgroundColor` only,
  never `borderWidth`: several controls draw their glyph as bordered boxes, so a
  border match returns a drawn arrowhead as the control's outline.
- Capture a screen's state **at the end of the whole walk**, not right after the
  press that reveals it. Home's `useQueries` waterfall had not resolved after 20
  `act` turns immediately post-launch; tabs and the stack below the top screen
  stay mounted, so everything can be read once at the end.

Related: [[mobile-contrast-harness]], [[render-real-navigator-in-jest]],
[[mobile-device-matrix-harness]].
