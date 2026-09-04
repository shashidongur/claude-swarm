---
name: session-lifecycle-in-jest
description: "How to move the auth session under a mounted RootNavigator in jest, and the two traps that make such tests lie"
metadata:
  type: gotcha
---

Render the real `AuthProvider` around the real `RootNavigator` (mock only
`aws-amplify/auth`, `../../config` with `IS_LOCAL_MOCK: false`, and
`src/api/apiClient`) to drive token expiry, sign-out and cold start against the
whole tree. See `mobile/src/screens/__tests__/SessionLifecycle.flow.test.tsx`.

Two traps:

1. **Auth is genuinely async.** `checkAuthState` awaits `getCurrentUser` → the
   session → `/users/me` before the tree branches and the screens' queries even
   start. A fixed count of `await Promise.resolve()` (the pattern in
   `NavigationGraph.flow.test.tsx`, which mocks `useAuth` and so is synchronous)
   settles nothing; loop ~8 `act(async () => setTimeout(…, 0))` turns instead.
   Also settle *after* pressing a tab — the tab's screen mounts lazily and its
   query needs a turn.
2. **react-query keeps the last good `data` when a refetch fails.** So flipping
   the API to 401 while the app is open changes nothing on screen — the "app
   looks fine, nothing saves" state. The error state only appears on a fresh
   mount with an empty cache. Testing the two separately is the finding; testing
   only the first makes the pin pass for the wrong reason.

Related: [[render-real-navigator-in-jest]], [[android-back-button-in-jest]],
[[test-utils-navigation-mock-trap]].
