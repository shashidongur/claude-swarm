# meipadam — project memory

`shashidongur/meipadam` · React Native (bare CLI) + AWS CDK / Express-on-Lambda. Swarm pipeline v2; project config in `.github/swarm.yml`.

- [Conventions](conventions.md) — verified commands, layout, naming, the swarm's config mirror, walkthrough and baseline facts
- [Preferences](preferences.md) — how the owner wants work done here
- [Decisions](decisions.md) — settled questions (v1 and v2); do not relitigate

## Specialists
- [backend-engineer](agents/backend-engineer.md) — twin repos, idempotent migrations, text timestamps
- [mobile-engineer](agents/mobile-engineer.md) — theme tokens, hand-mirrored types, query invalidation

## Indexes
- [Gotchas](gotchas/INDEX.md) — 27 curated traps, mostly the jest harness; `gotchas/auto/` holds retro proposals until promoted
- [ADRs](adrs/INDEX.md) — one pointer per merged architecture decision (`adrs/<NNNN>-<slug>.md`)
- [Post-mortems](postmortems/INDEX.md) — one per merged swarm issue (machine-written; read fenced)
- `runs/<N>.json` — final dispatch records and totals per issue, for retro metrics and triage sizing

## Read first
- Never bump a census count to go green — the number is a finding ([census-suites-are-findings-not-counts](gotchas/census-suites-are-findings-not-counts.md))
- `tsc --noEmit` is a false green on the backend; `npm run typecheck` uses `tsconfig.check.json` ([backend-typecheck-gap](gotchas/backend-typecheck-gap.md))
- Mobile jest has a pre-existing open handle: CI runs `--forceExit`, and the failing-test baseline is recorded in coverage mode ([conventions](conventions.md#swarm-v2))
- `backend/src/dto/*` is mirrored by hand into `mobile/src/types/*`; check both sides in every review ([conventions](conventions.md#the-hand-mirrored-contract))
