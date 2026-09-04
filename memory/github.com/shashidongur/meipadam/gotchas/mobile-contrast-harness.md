---
name: mobile-contrast-harness
description: WCAG contrast measured off the rendered RN tree — where the helpers live and the two traps that shaped them
metadata:
  type: gotcha
---

`mobile/src/testing/contrast.ts` holds the WCAG 2.1 maths (parse/composite/luminance/ratio,
plus `wcagMinimum`), verified against published figures in
`src/testing/__tests__/contrast.test.ts`. `screens/__tests__/Appearance.flow.test.tsx`
walks the real navigator and computes each `Text`'s drawn colour and backdrop by
compositing its ancestors' `backgroundColor`/`opacity`.

**Why:** two non-obvious details decide whether the numbers are right.

**How to apply:**
- `opacity` is a *group* operation: draw the subtree opaquely, then blend the whole
  result once against what sits outside the group. Blending layer-by-layer instead
  reports a dimmed row 0.1 too high (1.83 vs the true 1.93).
- RNTL registers a cleanup `afterEach` at import, so a node captured in `beforeAll`
  throws "Unable to find node on an unmounted component" in the second test.
  Snapshot the *measurements* (plain data) in `beforeAll` and unmount, instead of
  holding tree nodes — one mount serves the whole file.
- `TouchableOpacity` flattens its own animated opacity to `1` on every row, so a
  "which elements are dimmed" filter needs `opacity < 1`, not `opacity !== undefined`.
- Large text is taken as `fontSize >= 18` or `>= 14` bold (Android Accessibility
  Scanner's sp rule), the lenient of the two readings — stated in the module header.

Related: [[mobile-device-matrix-harness]], [[render-real-navigator-in-jest]],
[[jest-mock-factory-and-timer-traps]].
