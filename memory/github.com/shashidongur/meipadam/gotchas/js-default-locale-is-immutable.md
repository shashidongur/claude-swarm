---
name: js-default-locale-is-immutable
description: The JS default locale cannot be changed at runtime anywhere (not even outside jest) — build a locale axis by substituting an explicit tag into the same Intl call the app makes with undefined
metadata:
  type: gotcha
---

V8 resolves the default locale **once**, from the environment the process started
in, and exposes no runtime setter. `process.env.LANG = 'de-DE.UTF-8'` leaves
`Intl.DateTimeFormat().resolvedOptions().locale` reading `en-US` in plain
`node -e` as well as inside jest. Only `LANG=de-DE node …` works — i.e. the
mechanism is testable from the shell and not from inside the runner.

**Why:** this is a worse version of the [[jest-tz-switching-is-inert]] trap. For
TZ, the shell probe at least behaves differently from jest, which is a hint. Here
the only working form is one you cannot reach from a test at all, so a locale
sweep written the obvious way silently measures one locale N times.

**How to apply:** `mobile/src/testing/locales.ts` is the working shape. The app
passes `undefined` as the locale at every `Intl` / `toLocale*` call site (i.e. it
asks for the device locale), so substituting a real tag into the *same* call
reproduces what that device draws. Each helper is a mirror of a shipped formatter
with one argument changed, and
`mobile/src/testing/__tests__/localeControl.test.ts` ties every mirror back
byte-for-byte to the shipped function at the runner's own locale before any
finding leans on it — plus pins the negative result as its first test.

Two corollaries worth remembering: build test instants from a **local** wall
clock (`new Date(2026, 7, 2, 17, 30)`) so a locale table does not depend on the
runner's zone (this repo's jest runs in `America/New_York`, not UTC); and `Intl`
currency output contains ` ` and, for RTL locales, a leading `‏`, so
`toBe` on a hand-typed string fails on invisible characters.
