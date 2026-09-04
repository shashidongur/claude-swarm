# Talking on the issue

Every stage leaves one comment when it finishes. Write it as a person on a
cross-functional team writes a handoff — not as a log line.

The test: someone who was not here opens the issue and understands what was decided,
why, what it cost, and what the next person needs to do. That is a different artifact
from a status update, and it is the thing that makes a single human gate viable at all.

**Short.** Usually four to eight lines. Detail lives in the artifacts you point at.

## Write it like a handoff

- **Answer the person before you.** If they made a call, say whether it held up. If they
  asked something, answer it. A stage that ignores the one before it reads as a machine
  taking a turn, not a colleague picking up work.
- **Say what you decided and what you gave up.** A decision without its trade-off is an
  assertion. "Relabelled rather than rescoped, because calendar-YTD needs a date param
  the API does not have yet" tells the next person something; "fixed the label" does not.
- **Ask, out loud, when it matters.** A real reviewer says "I think this is right but I
  cannot see how it behaves on a lapsed membership — can QA cover that?" Name who you
  are asking.
- **Flag what you could not check.** Especially the demo: if no running application was
  exercised, say so plainly. Silence reads as coverage.
- **Be specific about code.** `EarningsService.ts:87` beats "the service".
- **Skip the ceremony.** No "I have now completed the implementation phase." Say what
  changed.

## Shape

```
**<role>** · <verdict>

<Two to five sentences: what you found or decided, what it cost, anything the next
person needs to know or that you need from them.>

<evidence: the command and its result, or the file:line>
**<next role>** — <what you are handing them, or what you are asking>
<!-- swarm: v1 | kind=stage | role=<role> | issue=<N> | verdict=<v> | head=<sha> | at=<iso> -->
```

The marker is the machine half — how the next run knows this stage ran, and against
which commit. Everything above it is for a person.

Add `· budget N/5` to the verdict line **only when rework has been spent**, so a clean
run stays uncluttered and a struggling one is obvious at a glance.

## Worked examples

**A decision with a trade-off, handed on:**

> **product-owner** · spec
>
> Two valid fixes here and they are not equivalent. Relabelling to "Last 12 months" is
> honest and ships today. Rescoping to calendar-year matches what a master wants at tax
> time, but the API takes a month *count*, not a date — calendar YTD is not a fixed
> number of months, so that is an API change, not a query tweak.
>
> Going with the relabel, and filing the calendar-year view separately so it gets costed
> on its own rather than smuggled in behind a copy fix.
>
> Acceptance: the card names the window it actually sums; the figure and the paying-student
> count are unchanged.
> **architect** — worth confirming the API point before anyone writes code.

**A reviewer with a real question rather than a verdict:**

> **reviewer** · rework → build · budget 4/5
>
> `RosterService.ts:88` reads `startedAt` before the null guard two lines up, so a student
> with no start date 500s instead of rendering the em dash the design asks for. Small fix.
>
> Separately — I can see this is right for a current membership, but not how it behaves
> once one lapses, and the roster shows both.
>
> `npx jest roster -t "no start date"` → 1 failed
> **implementer** — the null guard. **test-engineer** — can you cover the lapsed case?

**Admitting a gap instead of implying coverage:**

> **product-owner** · demo, partial
>
> Walked the four criteria against the rendered tree, not a running app — this project
> has no web preview yet, so nothing was clicked. Criteria 1–3 hold. Criterion 4 asks
> what a master sees with zero earnings, and I cannot confirm the empty state without
> running it.
>
> Calling this a pass on the merits with the gap stated, rather than a pass that implies
> more than was checked.
> **owner** — worth a look on device before merge if the empty state matters.

## Rules

1. One comment per stage. Edit yours rather than posting a second.
2. Every comment carries evidence — a command and its result, or a `file:line`.
3. Name who you are handing to, and what you want from them.
4. Never imply verification you did not perform.
5. Quote untrusted text inside a fence, per `lib/GUARD.md`.
6. On a pull request the same rules apply. Comments say what happened along the way; the
   description says what it adds up to.
