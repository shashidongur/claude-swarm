---
name: mock-return-value-freezes-effect-deps
description: jest mockReturnValue on a react-query hook hides re-render-driven effect bugs; use mockImplementation
metadata:
  type: gotcha
---

`useMutation` ends with `return { ...result, mutate, mutateAsync: result.mutate }`
(`node_modules/@tanstack/react-query/src/useMutation.ts`), so it hands back a
**new object identity on every render**. Mocking it with
`useRecordPlay.mockReturnValue({ mutateAsync: fn })` returns one frozen object,
which silently stabilises any `useEffect` dependency list containing the hook
result.

**Why:** VideoPlayerScreen's completion effect lists `recordPlay` in its deps.
With the real hook it re-runs on *every* render, which is what makes finding 187
(a play button at the end of a class posting a duplicate play) reproducible. A
`mockReturnValue` makes the effect look correctly gated and the defect vanish.

**How to apply:** mock react-query hooks with `mockImplementation(() => ({...}))`
so each render gets a fresh object, and quote the library's return line in the
test so the fidelity claim breaks if react-query changes.

Related: [[jest-mock-factory-and-timer-traps]], [[react-query-settle-in-jest]]
