---
name: mobile-device-matrix-harness
description: How the mobile device-matrix test harness works and the two jest traps it had to route around
metadata:
  type: gotcha
---

`mobile/src/testing/` holds a device-matrix harness (added 2026-08-02) that renders screens
at real iPhone/Samsung canvases instead of jest's single hard-coded 750x1334. Matrix in
`devices.ts`, harness in `deviceHarness.ts`, mutable active-device holder in
`currentDevice.ts`. Findings and share derivation live in `docs/device-matrix.md`.

Two jest traps shaped the design and will bite again:

1. **`jest.resetModules()` / `isolateModules` also resets React.** A component built by one
   React instance cannot be rendered by another — you get
   `Cannot read properties of null (reading 'useRef')`. So `loadOnDevice()` re-requires
   `react-native` *and* the renderer inside the same fresh registry, and returns the
   matching `renderTree` plus that registry's `ReactNative` (needed because
   `StyleSheet.flatten` only resolves ids its own instance registered).
2. **RNTL registers `beforeAll`/`afterAll` at import**, so re-requiring
   `@testing-library/react-native` inside a test body throws
   "Hooks cannot be defined inside tests". `loadOnDevice` uses bare
   `react-test-renderer` instead. Only `ExerciseCard` needs isolation at all (it reads
   `Dimensions` at module scope); everything else uses plain `applyDevice` + RNTL.

Screen padding lives on `contentContainerStyle`, not `style` — use `scrollContentStyles()`,
not `hostStyles()`, to assert safe-area or tab-bar padding.

`landscape(device)` (added to `devices.ts` 2026-08-02) returns the same size class rotated —
axes swapped, insets rotated: on a notched iPhone the status bar goes (top 0), the housing
depth reappears on **both** horizontal edges, and the home indicator drops 34→21; the SE goes
to all zeros; Samsung's bars are unchanged. `renderOnDevice(landscape(d), …)` then needs no
other change. `Rotation.devices.test.tsx` is the only suite that uses it.

Tree-wide source scans in that file must exclude `src/testing/` as well as `__tests__` — the
harness's own docs now mention orientation/landscape, and a scan that swept them in reported
the app as handling rotation.

Known defects are pinned with `it.failing(...)` so a fix turns the test red and forces the
record to be updated. See [[mobile-jest-hangs-after-pass]].
