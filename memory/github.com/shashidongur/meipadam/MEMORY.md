# meipadam — project memory

`shashidongur/meipadam` · React Native (bare CLI) + AWS CDK / Express-on-Lambda.

- [Conventions](conventions.md) — verified commands, layout, naming, and the demo gap
- [Preferences](preferences.md) — how the owner wants work done here
- [Decisions](decisions.md) — settled questions; do not relitigate

## Specialists
- [backend-engineer](agents/backend-engineer.md) — twin repos, idempotent migrations, text timestamps
- [mobile-engineer](agents/mobile-engineer.md) — theme tokens, hand-mirrored types, query invalidation

## Gotchas
- [validate-tests-against-main](gotchas/validate-tests-against-main.md) — re-run branch-authored suites against main; a green pin can mean the defect was fixed
- [backend-typecheck-gap](gotchas/backend-typecheck-gap.md) — `tsc --noEmit` is a false green; use `tsconfig.check.json`
- [backend-memory-repo-save-in-place](gotchas/backend-memory-repo-save-in-place.md) — `save()` must replace in place, not `Object.assign`
- [repository-contract-suite](gotchas/repository-contract-suite.md) — the only guard on memory/Postgres parity
- [memory-store-hides-row-order](gotchas/memory-store-hides-row-order.md) — memory returns insertion order; Postgres reads declare no ORDER BY
- [memory-store-hides-races](gotchas/memory-store-hides-races.md) — concurrent requests serialise; race tests need a yielding decorator
- [mobile-device-matrix-harness](gotchas/mobile-device-matrix-harness.md) — real device canvases, and two module-registry traps
- [mobile-contrast-harness](gotchas/mobile-contrast-harness.md) — WCAG ratios off the rendered tree; opacity is a group op
- [affordance-harness](gotchas/affordance-harness.md) — which pixels look pressable; the opacity chain double-counts
- [mock-return-value-freezes-effect-deps](gotchas/mock-return-value-freezes-effect-deps.md) — mock with mockImplementation or the bug vanishes
- [react-query-settle-in-jest](gotchas/react-query-settle-in-jest.md) — one act() per macrotask turn
- [microtask-settle-hides-navigation](gotchas/microtask-settle-hides-navigation.md) — Promise.resolve() loops read a frame early
- [test-utils-navigation-mock-trap](gotchas/test-utils-navigation-mock-trap.md) — import order silently overrides your nav mock
- [jest-mock-factory-and-timer-traps](gotchas/jest-mock-factory-and-timer-traps.md) — imports hoist above const; RNTL hangs on faked setImmediate
- [mobile-jest-hangs-after-pass](gotchas/mobile-jest-hangs-after-pass.md) — pre-existing open handle; use --forceExit
- [render-real-navigator-in-jest](gotchas/render-real-navigator-in-jest.md) — the whole RootNavigator mounts; safe-area mock needs .default
- [crawl-the-navigator-in-jest](gotchas/crawl-the-navigator-in-jest.md) — one fresh mount per press or the crawl invents edges
- [session-lifecycle-in-jest](gotchas/session-lifecycle-in-jest.md) — async auth needs macrotask turns; react-query hides a 401
- [android-back-button-in-jest](gotchas/android-back-button-in-jest.md) — spy BackHandler; read the top screen off the container ref
- [double-tap-in-jest](gotchas/double-tap-in-jest.md) — two presses in one act() model a real double tap
- [resize-a-mounted-tree-in-jest](gotchas/resize-a-mounted-tree-in-jest.md) — Dimensions.set fires a real change event
- [jest-collection-time-render-trap](gotchas/jest-collection-time-render-trap.md) — a per-device it.failing predicate cannot render
- [jest-tz-switching-is-inert](gotchas/jest-tz-switching-is-inert.md) — process.env.TZ moves Date in node, not in jest
- [js-default-locale-is-immutable](gotchas/js-default-locale-is-immutable.md) — process.env.LANG never moves Intl at runtime
- [screen-title-has-no-header](gotchas/screen-title-has-no-header.md) — headerShown is false everywhere; the title is the largest bold run
