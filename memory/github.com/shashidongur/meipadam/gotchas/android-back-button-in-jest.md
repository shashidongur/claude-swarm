---
name: android-back-button-in-jest
description: "How to press the Android system back button against the real navigator in jest, and how to read which screen is on top"
metadata:
  type: gotcha
---

Jest loads React Native's **iOS** `BackHandler` (a no-op whose `addEventListener`
returns a dummy subscription), so hardware-back can never fire on its own. Spy on
`BackHandler.addEventListener` before rendering to capture the callback
`NavigationContainer`'s `useBackButton` registers, then call it — that callback is
exactly what Android invokes, and its return value is `false` when the app would
close.

Do **not** assert which screen is showing with `queryByText`: a bottom-tab
navigator keeps inactive screens mounted, so Home's text is still in the tree
while Courses is on top. Pass a `ref` to `NavigationContainer` and read
`ref.current.getCurrentRoute().name` (and `getRootState().routes` for the stack).

Both are used by `mobile/src/screens/__tests__/AndroidBack.flow.test.tsx`. Builds
on [[render-real-navigator-in-jest]].
