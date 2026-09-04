---
name: conventions
description: How the meipadam repo actually works — verified commands, layout, naming, and the demo gap
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

## Swarm mention prefix

`meipadam` — so roles are addressed as `@meipadam-swarm-product-owner`,
`@meipadam-swarm-reviewer`, and so on. All nine handles were confirmed unclaimed on
GitHub on 2026-09-04 (`gh api /users/<handle>` → 404 for every one), so a mention cannot
notify a stranger.

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

## The demo gap — read before running a Demo stage

**There is no runnable preview today, and no simulator or device has ever been run in
this project.** Every prior "user test" was code-reading of rendered JSX plus the jest
harness. The Demo stage cannot run until a preview exists.

What it needs: `react-native` aliased to `react-native-web`, a bundler config, and web
stubs for every native module the app imports — `react-native-fs`, `@notifee/react-native`,
the video player, and IAP. The backend half is already solved: `src/local.ts` with the
in-memory repositories and `seed-data.ts` gives a real API with realistic data and no
AWS dependency.

Until that exists, Demo runs against the device-matrix harness and **must say in its
verdict that no running application was exercised**.
