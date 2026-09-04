---
name: memory-store-hides-races
description: "The in-memory repo resolves synchronously, so concurrent HTTP tests serialize — race tests need a yielding repository decorator"
metadata:
  type: gotcha
---

Concurrency tests driven through supertest **cannot** reproduce read-modify-write races against the in-memory store. Its repository methods are `async` but resolve synchronously (no real I/O), so an Express handler runs start-to-finish inside one microtask chain and the next HTTP request — a macrotask — is never dispatched mid-flight. `Promise.all([req1, req2])` therefore serializes.

Verified concretely (2026-07-21): a 7-test HTTP "concurrency" suite for live-session enrollment passed **identically with the optimistic lock removed**. It was proving nothing.

**How to actually test a race here:** drive the *service* directly with a repository decorator that yields a macrotask per call, modelling a network data layer:

```ts
const tick = () => new Promise<void>(r => setImmediate(r));
{ async findById(id) { await tick(); return inner.findById(id); },
  async save(s)      { await tick(); return inner.save(s); }, ... }
```

With that, 9 of 11 tests in `__tests__/live-sessions-concurrency.test.ts` fail when the lock is removed.

**Why:** this is the same property that makes the race invisible in dev and catastrophic on Postgres/DynamoDB — real I/O yields at exactly the read-modify-write boundary. Any future concurrency fix (messaging unread counts, progress upserts) needs the same harness.

**How to apply:** always confirm a concurrency test fails against the unfixed code before trusting it. Related: [[backend-memory-repo-save-in-place]].
