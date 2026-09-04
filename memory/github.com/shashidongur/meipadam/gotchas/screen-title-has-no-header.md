---
name: screen-title-has-no-header
description: "The app sets headerShown:false in every navigator, so \"what is this screen called?\" has to be read as the largest bold text run"
metadata:
  type: gotcha
---

Every navigator in `mobile/src/navigation/` sets `headerShown: false`, so there is
no platform title anywhere in the app. To ask "what does this screen call itself"
in a test, read **the largest bold text run inside that screen component's own
subtree** (`textRuns` from `src/testing/affordance.ts`, scoped with
`screen.UNSAFE_getByType(Component)`), excluding one-character runs — two screens
draw an avatar initial larger than their own title (`AccountSettingsScreen`'s is
36pt against a 30pt "Account").

**Why:** the rule is mechanical and checkable — it returns exactly the heading the
source declares on the screens that declare one (`Courses` 28pt, `Settings` 30pt
via `ScreenHeader`) — which is what lets a label-vs-destination table be a
measurement rather than an opinion.

**How to apply:** scope to the component, not the whole tree; a bottom-tab
navigator keeps every visited tab mounted and a stack keeps the screen below the
top one, so a tree-wide read answers for four screens at once. Related:
[[affordance-harness]], [[render-real-navigator-in-jest]].
