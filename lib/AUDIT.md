# Audit comments

Every stage leaves exactly one comment when it finishes. Someone opening the issue cold
must be able to read the whole history in under a minute — who did what, what they
found, what proved it, and where it went next.

**Short by default.** Five lines. The detail lives in the artifacts the comment points
at; the comment is the index, not the report.

## Format

```
**<role>** · <verdict> · <budget note>

<What happened. One or two sentences, plain. What was found, not what was attempted.>

`<the command that proves it>` → <its result>
→ <next stage, or what it is waiting on>
<!-- swarm: v1 | kind=stage | role=<role> | issue=<N> | verdict=<v> | head=<sha> | at=<iso> -->
```

The marker is the machine-readable half: it is how the next run knows this stage already
ran, and against which commit. The visible half is for a person.

`<budget note>` is `budget 5/5` when untouched, `budget 3/5` after two rework rounds, and
`budget reset by owner` after the owner asks for changes.

## Examples

A stage that passed:

> **test-engineer** · pass · budget 5/5
>
> Wrote the roster-row assertions and confirmed each fails against the unfixed
> commit first. The email column was the only one already covered.
>
> `npx jest issue39 --verbose` → 6 failed pre-fix, 6 passed post-fix
> → demo
> `<!-- swarm: v1 | kind=stage | role=test-engineer | issue=39 | verdict=pass | head=a1b2c3d | at=2026-09-04T04:12:00Z -->`

A stage sending work back — this is the one that has to be legible, because it is where
someone asks "why is this still open?":

> **reviewer** · rework → build · budget 4/5
>
> `RosterService.ts:88` reads `startedAt` before the null guard on line 84, so a
> student with no start date 500s instead of rendering an em dash.
>
> `npx jest roster -t "no start date"` → 1 failed
> → build (round 1 of the shared budget)
> `<!-- swarm: v1 | kind=stage | role=reviewer | issue=39 | verdict=rework | head=a1b2c3d | at=... -->`

A stage that stopped:

> **product-owner** · blocked · budget 0/5
>
> Three demo rounds all failed on the same criterion, and rewriting it did not
> converge. The requirement itself is ambiguous about which role sees the column.
>
> `docs/design/issue-39.md` → criterion 2 unresolved
> → blocked:budget — needs a decision from the owner
> `<!-- swarm: v1 | kind=stage | role=product-owner | issue=39 | verdict=blocked | ... -->`

## Rules

1. **One comment per stage completion.** Never a running log, never a second comment to
   correct the first — edit it.
2. **Say what was found, not what was attempted.** "Ran the suite" is not information.
   "19 of 21 pass; issue54's pins now pass because the guards landed" is.
3. **Every comment carries a command and its result.** A stage with no reproducible
   evidence has not passed; see `lib/OUTPUT-CONTRACT.md`.
4. **Name the next stage, or the thing being waited on.** A reader should never have to
   infer where the work went.
5. **Quote untrusted text inside a fence**, per `lib/GUARD.md`, if it must be quoted at
   all.
6. **On a pull request, the same rules apply**, and the PR description carries the
   accumulated evidence — the fail-then-pass output, the preview link, the verification
   table. The comments say what happened; the description says what it adds up to.

## What this is for

The swarm runs unattended for hours between the owner looking at it. Without a trail,
"why is this issue open, and what has already been tried?" costs a full re-read of the
diff. With one, it costs fifteen seconds. That difference is what makes a single human
gate viable at all.
