---
name: mobile-jest-hangs-after-pass
description: "mobile `npm test` passes then hangs on an open handle — pre-existing, use --forceExit when iterating"
metadata:
  type: gotcha
---

`cd mobile && npm test` prints "Jest did not exit one second after the test run has
completed" and then hangs, even though every suite passes and the exit code is 0.

**Why:** pre-existing open handle in the `src/screens` + `src/api` suites — reproduced on
those alone with no other files present, so it is not caused by anything added since.
Not yet diagnosed (`--detectOpenHandles` has not been run).

**How to apply:** when running the mobile suite while iterating, use
`npx jest --silent --forceExit`, otherwise a foreground run eats the full tool timeout.
Do not attribute the hang to newly added tests without first reproducing it on the
pre-existing suites. Related: [[mobile-device-matrix-harness]].
