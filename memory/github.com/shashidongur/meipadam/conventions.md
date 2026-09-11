---
name: conventions
description: How the meipadam repo actually works — verified commands, layout, naming, the swarm v2 config mirror, walkthrough and baseline facts
metadata:
  type: convention
---

React Native (bare CLI) client in `mobile/`, AWS CDK + Express-on-Lambda backend in
`backend/`. Two npm workspaces, separate lockfiles, no monorepo tool.

## Commands — all run and confirmed

| Purpose | Command | Note |
|---|---|---|
| backend typecheck | `cd backend && npm run typecheck` | → `tsc -p tsconfig.check.json`. **Not** the base config — see [[backend-typecheck-gap]] |
| backend CDK typecheck | `cd backend && npx tsc --noEmit -p tsconfig.json` | covers `bin/`, `lib/`, `lambda/` only |
| backend test | `cd backend && npm test` | needs `NODE_OPTIONS=--experimental-vm-modules`, already in the script |
| backend synth | `npx cdk synth -c cloudFrontPublicKey="$(cat key.pub)"` | generate a throwaway keypair first |
| mobile typecheck | `cd mobile && npm run type-check` | note the hyphen — backend uses `typecheck`, mobile uses `type-check` |
| mobile lint | `cd mobile && npm run lint` | deliberately no `--fix`; `lint:fix` is separate |
| mobile test | `cd mobile && npm test` | see [[mobile-jest-hangs-after-pass]] |
| install | `npm ci --legacy-peer-deps` (mobile) | RN's tree does not satisfy npm peer resolution |

**Verified 2026-09-03**: injecting `const x: number = "str"` into `backend/src/clock.ts`
is invisible to `tsc -p tsconfig.json` and caught by `npm run typecheck`. The base
config's `include` is `bin/`, `lib/`, `lambda/` — `src/` is simply absent.

## Test layout and naming

- backend: `backend/__tests__/*.test.ts` — 42 files. Domain suites by area
  (`memberships.test.ts`), plus one regression suite per filed issue:
  `issue<N>-<slug>.test.ts`.
- mobile: `mobile/src/**/__tests__/` — 88 files, three flavours: `*.devices.test.tsx`
  (device matrix sweeps), `*.flow.test.tsx` (cross-cutting scenarios), and
  `Issue<N>.<slug>.test.tsx` per filed issue.
- Helpers: `backend/__tests__/helpers.ts` (`resetDb`, `freezeClock`, the `*_AUTH`
  bearer constants) and `pglite.ts` (real Postgres in WASM, runs the actual migrations).
- **JSX tests must be `.tsx`.** A `.ts` test with JSX fails confusingly.

## Adding a feature, backend

New route module in `src/routes/*.routes.ts`, one `app.use(...)` line in `src/app.ts`,
one entry in `src/container.ts`. Routes are thin: parse → delegate → send.

**Every repository method is written twice** — `src/repositories/memory/` and
`postgres/` — and held to parity by `__tests__/repository-contract.test.ts`. See
[[backend-memory-repo-save-in-place]] and [[memory-store-hides-row-order]].

Migrations are append-only files in `src/db/migrations/`; **every statement must be
individually idempotent** because the Data API takes one statement per call with no
file-level transaction.

## The hand-mirrored contract

`backend/src/dto/*` is mirrored **by hand** into `mobile/src/types/*`. There is no
codegen. A rename must be carried across manually; the `'canceled'` vs `'cancelled'`
bug (silent status-comparison failures) is the cautionary tale. Check both sides in
every review.

## Design system

`mobile/src/theme/` — `colors`, `spacing`, `radius`, `shadow`, `typography`, and
`tabBarClearance`. Primitives in `mobile/src/components/ui/`. Never a raw hex value.
`mobile/src/testing/contrast.ts` enforces WCAG ratios against these tokens at test time,
so an off-token colour fails CI rather than shipping.

## Swarm (v2)

Pipeline v2 (`claude-swarm@v2`). The project's half is `.github/workflows/swarm-dispatch.yml`
(the stub) and **`.github/swarm.yml`** (the config the dispatcher reads fresh on every
event, from `main`; its blob sha is recorded in state). Per-issue artifacts land under
`docs/swarm/<N>/` on the integration branch `claude/issue-<N>-<slug>`; the signed state
file is `issues/<N>.json` on the orphan branch `swarm/state` (created 2026-09-08 through
the Git Data API, first commit 48a80b0). Never edit either from a swarm run.

### Lanes and commands — mirrored from `.github/swarm.yml`

Lane order is execution order: backend first, because `backend/src/dto/*` is the source
the mobile types mirror.

| Lane | Paths | Specialist | cwd | install | typecheck | test | lint |
|---|---|---|---|---|---|---|---|
| `backend` | `backend/**` | `agents/backend-engineer.md` | `backend` | `npm ci` | `npm run typecheck` | `npm run test:ci` | `npm run lint` |
| `mobile` | `mobile/**` | `agents/mobile-engineer.md` | `mobile` | `npm ci --legacy-peer-deps` | `npm run type-check` | `npm run test:ci` | `npm run lint` |

`test:ci` is the CI form — `jest --coverage --forceExit --json --outputFile=coverage/jest.json`
(backend with `NODE_OPTIONS=--experimental-vm-modules`); `npm test` stays the plain
local run. Other config values the roles get from the brief: `requirements_doc: REQS.md`,
`requirement_id_pattern: ^(FR|NFR)-[A-Z]+-[0-9]+$`, `pin_marker: it.failing(`,
`test_paths: backend/__tests__/**, mobile/src/**/__tests__/**, mobile/.maestro/**`,
`contract_command: node mobile/scripts/contract-diff.js --report-only`,
`walkthrough_when: mobile/**`, `sensitive_paths` = apple / membership / earnings /
auth middleware / analytics on the backend, `purchases*` and `auth/**` on mobile.
`evidence: { ci: CI, test: walkthrough, security: security }`.

### Mention handles — retired

v2 writes no mentions except one approver login in a gate comment. For the record, a
GitHub user search for `meipadam in:login` and `meipadam-swarm in:login` returned
`total_count: 0` on 2026-09-06 — no account's login contains "meipadam", so every
`@meipadam-swarm-<role>` handle of v1 was free and remains free; there is nothing to
re-check per role.

### Approvers

Repository owner `shashidongur`, `gh api users/shashidongur --jq .type` → `User`; the
config's `approvers.*` lists are empty, so every gate and command falls back to the
owner. Gate 3 counts only when that login merges the PR.

### The device walkthrough (`.github/workflows/walkthrough.yml`, evidence `test`)

- Builds the **debug** APK: `cd mobile/android && ./gradlew :app:assembleDebug
  -PreactNativeArchitectures=x86_64 --no-daemon` (cleartext traffic and the debug
  keystore are by design; both are allow-listed for the secret scan).
- The emulator reaches the host's mock backend at **`10.0.2.2:3000`** (`PORT=3000
  DATA_STORE=memory APPLE_VERIFIER=fake NODE_ENV=test npm run dev` in `backend/`, wait
  for `/health`); Metro at 8081 via **`adb reverse tcp:8081 tcp:8081`**.
- **Warm the bundle before timing anything**: `curl -sf
  'http://localhost:8081/index.bundle?platform=android&dev=true&minify=false'` takes
  1–3 min on first request; without it the cold-start numbers measure Metro, not the
  app. `SUMMARY.md` states that the bundle was pre-warmed.
- The NDK (`26.1.10909125`) and the `android-34 google_apis x86_64` system image are
  downloaded by `sdkmanager` and cached keyed on version only — most runs are cold at
  3–4 issues a month. **Budget the walkthrough at its cold figure**: estimated 15–25 min
  (8–12 warm); the measured time from the first hand run goes here.
- Flow files under `mobile/.maestro/`. **Text selectors are regular expressions**:
  `"Student (Arun Kumar)"` compiles as a group and never matches the on-screen label.
  Escape `( ) . + ?` or use a wildcard (`".*Arun Kumar.*"`). Splash ≈ 3.4 s, so the
  first `extendedWaitUntil` uses a 15 s timeout. One `testID` exists in the app; the
  rest is visible text. The pinned tool versions live in `.github/scripts/walkthrough.sh`.
- Visual regression needs baseline PNGs under `mobile/.maestro/baselines/<flow>/`
  captured from the pinned AVD profile; until they exist the manifest says
  `visual: {ran: false, reason: "no baseline images"}` and qa repeats it.
- iOS is never exercised (no macOS runner on this plan); every qa/security report says
  so.

### Baselines — what "CI red" means here

- **Mobile jest is baselined, in coverage mode.** `mobile/jest.baseline.json` lists the
  tests that fail on `main`, recorded with `npm run test:ci` (coverage on, `--forceExit`)
  and checked by `mobile/scripts/jest-baseline.js check`. Measured 2026-09-06 on
  `origin/main` (fff7853): **91 failing** with instrumentation on versus **52** without —
  coverage slows the timing-sensitive suites — so the baseline must be recorded and
  checked in the same mode CI runs, and `check` refuses a baseline whose `mode` is not
  `coverage`. CI tolerates jest's exit code (`set +e`) so the baseline check can run;
  `coverageThreshold` is kept out of both jest configs so the exit code means one thing.
- **Coverage** is checked by `scripts/coverage-check.js` with thresholds in `ci.yml`
  env, re-measured at switch-on with the shipped `collectCoverageFrom` and set 2–3
  points under. Addendum figures with the wider glob, for orientation only: mobile
  lines 83.04 / functions 78.90 / branches 78.22 (suggested 80/75/75); backend lines
  88.31 / functions 86.32 / branches 72.48 (suggested 85/83/70). Full suite only.
- **`npm audit` is baselined**: `backend/audit.baseline.json`, `mobile/audit.baseline.json`
  (`scripts/audit-baseline.js record`, `--package-lock-only`, no `npm ci` in the scan
  job). On `origin/main` at switch-on: **backend 9 high + 1 critical, mobile 20 high +
  2 critical**, mostly transitive RN/CDK — an unbaselined `--audit-level=high` is red on
  every branch forever. `check` fails only on ids absent from the baseline.
- **Semgrep** uses `--baseline-commit $(git merge-base origin/main HEAD)`; nothing to
  maintain. `.semgrepignore` excludes `node_modules/`, the `.cxx/` tree, `__tests__/`,
  `docs/`, `coverage/`.
- **gitleaks is never baselined.** The history was scanned once at switch-on;
  `.gitleaks.toml` allow-lists only the debug keystore, the `.cxx/` tree and the
  `'android'` debug signing passwords in `build.gradle`.
- All baseline files, `scripts/**`, `**/jest.config.*`, `.gitleaks.toml`,
  `.semgrepignore`, `docs/promises.md` and `mobile/android/app/.cxx/**` are
  `protected_paths`; the `test:ci`/`test`/`lint`/`typecheck`/`type-check` scripts and
  `jest` blocks of both `package.json` files are diffed against the merge base. A dev
  cannot make CI green by editing the gate; it says `blocked` instead.
- Census constants ([[census-suites-are-findings-not-counts]]) are never bumped to go
  green, and a baseline entry is removed only with the fix that made it pass.

### CI runs once per push

`ci.yml` triggers on `pull_request` and on `push` to `main` only — no `push: claude/**`.
The test-writer's first push is followed by `gh pr create --draft` in the same turn, so
CI runs on that sha within seconds; a push trigger as well would run every head twice.
Concurrency group `CI-<head ref>` with `cancel-in-progress: true`.

## Branch and PR naming

Branches: `claude/issue-<n>-<slug-or-timestamp>`. PR titles are either conventional
commit (`fix(FR-AUTH-09): ...`) or a plain imperative sentence ending `(#58)`.

## Requirements and coverage

`REQS.md` — 227 ids, `FR-<AREA>-<NN>` / `NFR-<AREA>-<NN>`, in
`| ID | Requirement | Roles | Status |` tables. Status is `Done | Mock | Partial |
Planned`. Roles abbreviate S / M / A / · (any authenticated) / ∅ (unauthenticated).

`docs/promises.md` — the role-facing capability ledger (STU/MAS/ADM), status
`Done | Mock | Partial | Planned | Risk`, synced to issues by
`.github/workflows/promises-sync.yml`. **Owned by that workflow — never edit it.**

Coverage log: `docs/master-role-requirement-testing.md`. Master is fully swept;
**Student and Admin are untouched.**

## The demo gap — history, and what replaced it

v1 had a Demo stage and no way to run the app; v2 replaces it with the device
walkthrough above (an emulator on CI, fired as evidence before `qa`). Kept for the
record:

**There was no runnable preview before 2026-09, and no simulator or device had ever
been run in this project.** Every prior "user test" was code-reading of rendered JSX
plus the jest harness.

What it needs: `react-native` aliased to `react-native-web`, a bundler config, and web
stubs for every native module the app imports — `react-native-fs`, `@notifee/react-native`,
the video player, and IAP. The backend half is already solved: `src/local.ts` with the
in-memory repositories and `seed-data.ts` gives a real API with realistic data and no
AWS dependency.

Until that exists, Demo runs against the device-matrix harness and **must say in its
verdict that no running application was exercised**.
