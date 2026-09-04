---
name: jest-mock-factory-and-timer-traps
description: "Two mobile-jest traps — a mock factory that reads undefined from a module-scope const, and RNTL cleanup hanging on faked setImmediate"
metadata:
  type: gotcha
---

Mocking a native module whose spies must survive `jest.isolateModules`, and using
fake timers around a rendered screen, each have one trap in `mobile/`:

**Mock factory + module-scope object.** ES `import`s are hoisted above `const`
initialisation, so a factory written as `const mockRnfs = {...}; jest.mock('x', () => mockRnfs)`
hands back `undefined` when the module under test is imported at file scope
(`Cannot read properties of undefined`). Declare it as `let mockRnfs;` and build
it *inside* the factory (`mockRnfs = mockRnfs || {...}`) — babel-plugin-jest-hoist
allows the `mock`-prefixed name, and every later module registry (including one
created by `jest.isolateModules`) gets the same spies, which is what makes a
"relaunch the app over the same disk" test possible.

**RNTL cleanup + fake timers.** `@testing-library/react-native` registers
`afterEach(cleanup)` at import, and it hangs (5s hook timeout, blamed on the
import line) when the unmounted tree still holds a pending promise and
`setImmediate` is faked. `jest.useRealTimers()` in a describe-level `afterEach`
does not help — RNTL's hook runs first. Use
`jest.useFakeTimers({ doNotFake: ['setImmediate'] })`.

Related: [[mobile-device-matrix-harness]], [[mobile-jest-hangs-after-pass]],
[[session-lifecycle-in-jest]].
