# Routing — who hands to whom

The single source of truth for the pipeline graph. Before this file, forward routing was
undefined: the orchestrator was told to "spawn the role by name … and so on", and only
three of nine roles named a successor, all of them backwards. Routing is now data.

Two things carry the baton, deliberately:

- **The mention** — a line addressed to the next role. It is what fires the next run.
- **The label** — the stage the work has moved to. It is what lets the work be recovered
  if a mention is malformed or a run dies.

Neither is decoration. If they disagree, the work stops.

## The mention grammar

    **@<project>-swarm-<role>** — <one line: what you are handing them, or asking>

Exactly one such line, immediately before the marker comment, and nothing after it. The
project prefix is read from the project's `conventions.md`; for
a project called `acme` it is `acme`, giving `@acme-swarm-reviewer`.

The prefix exists so one swarm working three repositories never crosses wires, and so a
mention can never collide with a real GitHub account. **Before a project's first run,
confirm none of its handles exist** — `gh api /users/<handle>` must 404 for every role.
A collision means every handoff notifies a stranger.

## The table

| Role, at this stage | On `pass` | On `rework` |
|---|---|---|
| *(issue filed / labelled `swarm:triage`)* | `product-owner` | — |
| `product-owner` — spec | `architect`, plus `designer` first if it has an interface | — |
| `designer` | `architect` | — |
| `architect` | `implementer` | — |
| `implementer` | `reviewer` | — |
| `reviewer` | `test-engineer` | `implementer` |
| `test-engineer` | `product-owner` *(for the demo)* | `implementer` |
| `product-owner` — demo | opens the PR, then `owner` | `architect` *(re-specs first)* |
| `owner`, commenting on a swarm PR | `product-owner` — **always** | — |

`owner` is the human. It is the only address that is not a role — and it is written as
**their actual login**, which the dispatch supplies. Never the literal `@owner`: that is a
real GitHub organisation, and addressing it notifies strangers on every handoff.

The role handles were all checked for collisions before the first run (`gh api /users/<h>`
→ 404 for each). `@owner` was not, and slipped through. Check every literal handle in a
template, including the ones that look like placeholders.

**Why your feedback goes to the product-owner rather than straight to the implementer:**
it is not yet known whether you found an implementation problem or a specification one.
Sending a specification misunderstanding to the implementer gets it rebuilt, not
re-specified. The product-owner triages and routes on — which also means you never have
to decide which kind of problem you found.

## Three rules that keep the graph safe

1. **A role may never address itself.** A comment whose `next=` equals its own `role=` is
   refused, and the issue is set `blocked:self-dispatch`. This is the shortest possible
   infinite loop and it is worth a specific guard.
2. **Only a role in this table may be addressed.** An unrecognised mention is ignored,
   never guessed at. A typo should stall the work visibly, not route it somewhere
   plausible.
3. **Exactly one mention line per comment.** Fan-out has no defined join — nothing in
   this design knows how to wait for two roles to finish — so a comment naming two
   recipients is rejected rather than half-honoured.

## Rework, and where the budget lives

`reviewer → implementer`, `test-engineer → implementer`, and
`product-owner (demo) → architect` are the three backward edges. They share **one budget
of five per issue**.

There is no orchestrator holding that count any more, so it is **derived**: count the
comments on the issue whose marker carries `verdict=rework`. Five or more, and the next
dispatch refuses and sets `blocked:budget` instead of running.

The owner's own feedback is **never counted and resets the budget**, which in the derived
model means: only count `verdict=rework` markers posted *after* the most recent comment
authored by the owner.

## Starting and ending

**Starting.** Applying `swarm:triage` to an issue dispatches the `product-owner`. A human
may also start it by writing the mention directly.

**Ending.** The `product-owner` opens the PR and addresses `owner`. The swarm then stops
and waits. There is no automatic path past your merge — that is the single gate, and it
is not something a role can address its way through.
