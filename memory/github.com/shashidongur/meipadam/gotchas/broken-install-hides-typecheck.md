---
name: broken-install-hides-typecheck
description: A failing npm ci masks every later CI step — mobile code added since 2026-09-01 was never typechecked at all
metadata:
  type: gotcha
---

CI's mobile job runs `npm ci` → `type-check` → `lint` → `test`, in that order and in one
job. When `npm ci` fails, **every later step is skipped, not failed**, so the run is red
for one reason while an unknown number of other defects accumulate unseen behind it.

That is exactly what happened. The avatar-upload merge added
`react-native-image-picker` to `package.json` without the lockfile, so `npm ci` refused
from that commit onward. When the lockfile was repaired, the job reached `type-check`
for the first time and immediately failed on code from the same merge:

    AccountSettingsScreen.tsx(63,33): error TS2345
      Type 'number' is not assignable to type 'PhotoQuality | undefined'.

`quality: 0.8` widens to `number`; the library's `PhotoQuality` is a union of literals
(`0 | 0.1 | ... | 1`). The author had written `mediaType: 'photo' as const`, so the
idiom was already there — it was just missed on the neighbouring property.

**Why:** a red baseline does not merely block work, it *accumulates* it. The longer the
first step stays broken, the more untypechecked code lands behind it.

**How to apply:** when repairing a red pipeline, expect the fix to reveal a second
failure rather than turn the run green. Budget for that, and fix them in one pull
request so a single merge restores the baseline. Never assume a red job means one defect.

See also [[validate-tests-against-main]] — the same run also showed two regression
suites had drifted from `main`.
