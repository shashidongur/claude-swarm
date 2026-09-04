---
name: backend-memory-repo-save-in-place
description: "Memory repo reads return copies; save() must UPDATE the canonical record in place via replaceInPlace — not Object.assign (merges), not slot replacement (orphans references)"
metadata:
  type: gotcha
---

In the layered backend (`backend/src/repositories/memory/*`), the two halves of the memory-store contract must both hold, or tests break:

1. **Reads return copies** (`{...row}` / deep-clone for nested records like `LiveSessionSeries`). This makes `save()` load-bearing exactly as it is under Postgres — a caller that mutates a read entity and forgets to `save` loses the change in both impls.
2. **`save()` updates the canonical record IN PLACE** via `replaceInPlace(existing, incoming)` from `memory/store.ts` (an UPDATE by id), NOT `arr[i] = incoming` / `map.set(id, incoming)`. Replacing the slot orphans any held reference.

**Two corrections the repository contract suite forced** (both were live bugs in all ten repos):

- **Insert a copy, never the caller's object.** `push(x)` / `map.set(id, x)` aliased caller-owned state, so a later mutation changed the store without a `save` — the exact opposite of point 1.
- **`Object.assign` is not enough — it merges.** A whole-record save that omits a previously-set optional left the old value in place forever, while Postgres writes every column and clears it. `replaceInPlace` deletes the stored object's keys first, then assigns: identity preserved AND absent keys cleared. Postgres was the correct behaviour; `save` takes a `User`, not a `Partial<User>`, so it means "make the row equal this record".

Why #2 matters: some tests grab a live store reference (e.g. `const series = db.liveSessions.find(...)`), mutate its setup in place, hit an endpoint, then re-read the SAME reference to assert the result (waitlist renumbering in `live-sessions-series.test.ts`). The original inline routes mutated the live object directly, so this held. Clone-on-read + slot-replacing save broke it (2 failures); switching every `save` to in-place `Object.assign` restored it. This also honors `store.ts`'s identity-in-place philosophy and matches a real SQL UPDATE.

Applies to every update path. The Postgres impl is now written (`save` is a real upsert writing every column); this contract is what keeps the two interchangeable.

Related: [[backend-typecheck-gap]], [[repository-contract-suite]]
