---
name: render-real-navigator-in-jest
description: The real RootNavigator tree renders under jest; the safe-area jest mock must be unwrapped with .default or BottomTabView throws
metadata:
  type: gotcha
---

`mobile/src/screens/__tests__/NavigationGraph.flow.test.tsx` mounts the actual
`RootNavigator` inside a real `NavigationContainer` — no navigation mocking — with
only `../../auth/AuthContext` and `../../api/apiClient` stubbed. One axios stub
covers the whole api layer, because every hook goes through that client.

The trap: `jest.mock('react-native-safe-area-context', () => require('react-native-safe-area-context/jest/mock'))`
fails with `Cannot read properties of undefined (reading 'Consumer')` inside
`BottomTabView`. The package's jest mock is a **default export**, so the factory
must return `require('...jest/mock').default`.

**Why:** every other screen test mocks `useNavigation`, which can prove a control
calls `navigate('X')` but never what the app then shows — cross-navigator route
resolution, per-tab history and role gating are properties of the tree.

**How to apply:** for any finding about where the app *lands*, render the tree
rather than the screen. Address tab-bar buttons by walking up from the label Text
to the touchable with `minHeight: 30` — the bar has no testID or a11y label
(see [[test-utils-navigation-mock-trap]], [[mobile-device-matrix-harness]]).
