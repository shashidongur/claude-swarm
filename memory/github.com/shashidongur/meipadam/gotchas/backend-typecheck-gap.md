---
name: backend-typecheck-gap
description: backend/tsconfig.json does NOT typecheck src/ — use tsconfig.check.json to verify the restructure
metadata:
  type: gotcha
---

`backend/tsconfig.json`'s `include` is only `bin/**`, `lib/**`, `lambda/**` — it does **not** cover `src/**`, `local-server.ts`, or `__tests__/**`. So `npx tsc --noEmit` (which uses tsconfig.json) gives a **false green** for all the layered-restructure code in `src/`.

The real typecheck gates for `src/`:
- **`npx tsc -p tsconfig.check.json`** — a config added in step 6 that extends tsconfig.json and includes `src/**`, `seed-data.ts`, `__tests__/**`. Use this to verify restructure code.
- **Loading the server** via `npx ts-node src/local.ts` (WITHOUT `--transpile-only`) full-typechecks the app graph on load. Note `npm run dev` uses `--transpile-only`, so it skips typechecking.
- **`npm test`** does NOT typecheck — ts-jest has diagnostics disabled (see jest.config.ts).

**Why:** twice during the restructure, `tsc --noEmit` passed while ts-node caught real errors (Express 5 `req.params` being `string|string[]`; `string` not assignable to a string-literal union like `Course['level']`). Trust `tsconfig.check.json`, not bare `tsc --noEmit`.

Related: [[backend-restructure-progress]]
