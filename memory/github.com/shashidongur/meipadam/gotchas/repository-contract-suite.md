---
name: repository-contract-suite
description: One test suite runs every repository against both the in-memory store and real Postgres; it is the only guard on implementation parity
metadata:
  type: gotcha
---

`backend/__tests__/repository-contract.test.ts` runs a single set of assertions
twice — `describe.each([memoryTarget, postgresTarget])` — against the in-memory
repositories and against real PostgreSQL via PGlite (Postgres compiled to WASM,
so no Docker and no service container).

**Why:** every other backend suite exercises services over the memory store, so
a Postgres implementation could be wrong in any number of ways — NULL where
`undefined` is expected, a batch read that loses its grouping, an upsert keyed
on the wrong column, a page that orders a thread differently — and all of them
would still pass. On its first run it found two real bugs that had been sitting
in the memory repositories: every one of the ten stored the caller's object by
reference, and `save` merged rather than replaced, so a record saved without a
previously-set optional kept the old value forever.

**How to apply:** any change to a repository interface or either implementation
belongs here first. Deliberate differences go in the `divergences` block with
the reasoning (foreign keys, the one-subscription-per-pair rule, the
video-delete → progress cascade) rather than being smoothed over. Properties no
query against PGlite can demonstrate — the `COLLATE "C"` pin on
`messages.message_id` is the one so far — go in `schema guarantees` and are
asserted against the catalog, because a test that cannot fail is not evidence.

Related: [[backend-memory-repo-save-in-place]], [[backend-typecheck-gap]],
[[memory-store-hides-races]].
