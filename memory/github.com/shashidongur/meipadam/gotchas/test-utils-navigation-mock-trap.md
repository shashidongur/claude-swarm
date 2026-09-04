---
name: test-utils-navigation-mock-trap
description: "mobile/src/test-utils.tsx registers its own jest.mock for @react-navigation/native; importing it before the screen silently overrides the test file's own navigation mock"
metadata:
  type: gotcha
---

`mobile/src/test-utils.tsx` has a top-level `jest.mock('@react-navigation/native', …)`
returning *its* `mockNavigate`/`mockGoBack`. Whichever mock factory is registered
when the screen module is first required is the one that wins, so:

- `import Screen from '…'` **before** `import { renderWithQueryClient } from '../../test-utils'`
  → the test file's own factory is used (what the older screen tests rely on).
- test-utils imported first → its factory is used, and assertions on the test
  file's own `mockGoBack` silently see zero calls with no error anywhere.

**Why:** the symptom is a passing tap, a real network mock call, and a navigation
assertion that fails with "Received number of calls: 0" — nothing points at the
import order.

**How to apply:** in a new test file, define a local QueryClient wrapper instead
of importing `test-utils` (see `MasterAccess.flow.test.tsx`), or import the
screen first. Related: [[mobile-device-matrix-harness]].
