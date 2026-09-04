---
name: backend-engineer
description: meipadam's server-side specialist. Layers on the portable implementer with this codebase's invariants.
metadata:
  type: convention
---

Follow `agents/implementer.md` first. This adds what is true only here.

## Shape of a change

Route module in `src/routes/*.routes.ts` → one `app.use(...)` in `src/app.ts` → one entry
in `src/container.ts`. Routes stay thin: parse, delegate to a service, send. Business
logic lives in `src/services/`, pure rules in `src/domain/`.

## Invariants that are not obvious from the code

- **Every repository method is written twice** — `memory/` and `postgres/`. The pair is
  held to parity by `__tests__/repository-contract.test.ts`, which is the only guard
  against them drifting. See [[backend-memory-repo-save-in-place]].
- **Every `save` writes every column, including `created_at`.** Holding a column back is
  a silent memory/Postgres divergence, not an optimisation.
- **Timestamps are `text`, not `timestamptz`.** Postgres would normalise the spelling
  (`...00Z` → `...00.000Z`) and change the payload for every installed client.
- **Migrations are new files, never edited, and every statement is individually
  idempotent** (`IF NOT EXISTS`). They run at deploy time through a CDK Trigger, and the
  Data API takes one statement per call with no file-level transaction.
- **Ownership is checked before the work**, through the single `requireOwned` helper —
  existence first (404), then ownership (403), consistently.
- **Entitlement is one rule** in `domain/membership.ts`. Do not re-derive it at a call
  site; ask `MembershipService`.

## The typecheck

`npm run typecheck` → `tsc -p tsconfig.check.json`. The base `tsconfig.json` does not
include `src/` at all, so `tsc --noEmit` against it is a green run that means nothing.
See [[backend-typecheck-gap]].

## Test traps

[[memory-store-hides-row-order]] — memory repos return insertion order for ever, while
most Postgres list reads declare no `ORDER BY`, so an edited row moves to the end.
[[memory-store-hides-races]] — concurrent supertest requests serialise against the
in-memory store, so a race test needs a yielding decorator.
[[repository-contract-suite]] — the one suite that runs against both implementations.
