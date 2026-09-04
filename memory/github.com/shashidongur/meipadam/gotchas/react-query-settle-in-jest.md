---
name: react-query-settle-in-jest
description: "Settling real react-query hooks under RNTL needs one act() per macrotask turn, and enough turns for every leg of a request waterfall"
metadata:
  type: gotcha
---

Mobile tests that run the *real* react-query hooks against a mocked
`src/api/apiClient` must settle with **one `act()` per macrotask turn**, not one
`act()` containing many awaits:

```tsx
for (let i = 0; i < 20; i++) {
  await act(async () => { await new Promise(r => setTimeout(r, 0)); });
}
```

**Why:** query-core's `notifyManager` batches observer notifications through
`setTimeout(0)`, so microtask turns leave every render one state behind (and
React logs "not wrapped in act"). And a leg of a request waterfall only starts
once the previous leg's state is *committed* — flushing after all the awaits
instead of between them silently leaves the tree mid-waterfall, which reads as a
screen bug rather than a test-harness one.

**How to apply:** count the legs before choosing the turn count. `HomeScreen` is
three (`/memberships/me` → `/courses?masterId` → `/courses/{id}` +
`/progress/course/{id}`) and needs ~20 turns; 14 was not enough and the symptom
was a *control* test failing, not the pins. See [[session-lifecycle-in-jest]] for
the same lesson on the auth side, and `mobile/src/screens/__tests__/Latency.flow.test.tsx`
for the helper.
