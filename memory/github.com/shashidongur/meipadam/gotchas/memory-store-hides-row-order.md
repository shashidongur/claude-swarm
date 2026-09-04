---
name: memory-store-hides-row-order
description: "The in-memory repos return insertion order for ever, so no test can see that 17 of 24 Postgres list reads declare no ORDER BY"
metadata:
  type: gotcha
---

The in-memory repositories back their lists with a `Map`/array, so every read
returns insertion order, deterministically, for ever. The Postgres
implementations of the same access patterns mostly declare **no `ORDER BY`** —
17 of the 24 list reads, including all four of `CourseRepository` (the student's
whole catalogue). Postgres gives no row-order guarantee there; for a small table
it is heap order, and an `UPDATE` appends a new tuple version, so **an edited row
moves to the end**.

**Why:** every backend suite but `repository-contract.test.ts` runs against the
memory store, so a stable order is baked into ~2,850 assertions that production
does not provide. Same family of blind spot as
[[memory-store-hides-races]] — the memory impl is not just faster, it is
*more deterministic than the real thing*, in a direction that hides defects.

**How to apply:** to test anything order-dependent, run it against PGlite via
`createTestSqlClient()` (see [[repository-contract-suite]]). The reorder is
reproducible: save N rows, `save()` one of them again, re-read — it is last.
`backend/__tests__/list-ordering.test.ts` runs one suite against both targets and
marks the memory half `it.failing`, which states the divergence instead of
hiding it. `course_videos` is the counter-example: it has `sort_order`, an index
and an explicit `ORDER BY`, so the classes inside a course are the one stable
list in the product.
