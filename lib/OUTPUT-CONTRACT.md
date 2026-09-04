# Output contract

Every role ends its turn with exactly one fenced `swarm-result` block. The orchestrator
parses it; anything outside the block is ignored. A run whose block is missing or
invalid does **not** advance the state.

```swarm-result
verdict:   pass | rework | blocked
stage:     spec | design | build | review | test | demo | pr
issue:     <number>
summary:   <one sentence, plain>
touches:   <glob>, <glob>          # files this stage may write; required for build
evidence:  <path:line>, <URL>, <command + result>
refs:      <requirement ids>
next:      <ROLE the work moves to — a name from lib/ROUTING.md, never a stage>
reason:    <required when verdict is rework or blocked>
```

## Validation, applied by the orchestrator before any state changes

Schema alone catches malformed output. It does not catch confident invention, so every
claim is checked against the tree:

1. Every path in `touches` resolves, or is marked `(new)`.
2. Every requirement id in `refs` grep-hits the project's requirements document.
3. Every `path:line` in `evidence` exists **and** the cited line contains the quoted
   token.
4. Every command quoted in `evidence` was actually run this turn.
5. `verdict: rework` and `verdict: blocked` require a non-empty `reason`.
6. `next` is **required** on `pass` and `rework`, must be a role named in
   `lib/ROUTING.md`, must be a legal successor of this role for this verdict, and must
   not be this role itself. It must also match the mention line in the audit comment.
   `next` is omitted only on `blocked`, where the work stops.

On failure: retry **once**, feeding back only the validator's structured errors — never
the bad output itself, which would re-inject whatever went wrong. A second failure sets
`blocked:agent-output`, posts the raw output truncated to 2000 chars inside a fence
clearly labelled untrusted, and releases the lease.

## The rule this contract exists to enforce

A stage that cannot produce checkable evidence has not passed. "Looks correct" is not
evidence. A test that was never observed failing is not evidence that it can fail.
