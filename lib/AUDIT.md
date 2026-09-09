# Talking on the issue

Every dispatch leaves one comment on the issue. In v2 **the dispatcher writes it**: it
posts the working form when it claims the run, edits it into the final form when the
run's result has been validated, and it — never a role — writes the marker at the
bottom. A role's contribution to the thread is what it puts in `result.json`:
`summary`, `evidence[]`, `not_covered[]`, `artifacts[]`. Write those as a person on a
cross-functional team writes a handoff, not as a log line.

The test is unchanged from v1: someone who was not here opens the issue and understands
what was decided, why, what it cost, and what the next person needs to do. That is what
makes three human gates per issue viable at all.

## What the dispatcher renders

Emoji come from `pipeline.yml emoji`; one per role, one per verdict, in the header only.

| role | emoji | | role | emoji |
|---|---|---|---|---|
| triage 🔎 | analyst 🎯 | ux 🎨 | a11y ♿ | architect 📐 |
| threat-model 🛡️ | planner 🗺️ | test-writer 🧪 | dev 🔨 | code-review 🔍 |
| qa ✅ | security 🔐 | compliance 📋 | release 🚀 | retro 📓 |
| critic ⚖️ | dispatch 🧭 | gate 🛎️ | watchdog 🐕 | |

Verdict emoji: working ⏳ · pass ✅ · rework 🔄 · blocked 🚧 · question ❓ · died 💀 ·
superseded ⛔.

**Working** — posted by `resolve` the moment the dispatch is claimed, so a running stage
is never mistaken for one that did not fire:

```
🔨 **dev:app** · ⏳ running · attempt 1 · started 2026-09-06T14:41:39Z · https://github.com/…/actions/runs/1
<!-- swarm: v2 | kind=stage | issue=7 | stage=build | role=dev:app | attempt=1 | key=7:build:dev:app:1 | run=1 | status=running | at=2026-09-06T14:41:39Z -->
```

**Final** — edited by `advance` (first to "finished; routing…", then to this):

```
🔨 **dev:app** · ✅ pass · claude-sonnet-5 · $4.12 · 88 turns · 19m40s · 21 job-min · rework 1/5

<summary from result.json, verbatim after sanitisation, ≤ 900 chars>

Evidence
- `<test command> -- Issue7` → `Tests: 3 passed` (exit 0)
- `app/src/screens/LiveSessions.tsx:142` `capacityLabel`
- artifact `evidence/CI/SUMMARY.md` — CI success on f54b320

Artifacts: docs/swarm/7/review-app-a1.md (staged, lands with the next push) · head f54b320 · PR #9 · audit swarm-7-build-dev-app-a1-1
Not covered: iOS not exercised (no macOS runner)
Next: code-review:app
<!-- swarm: v2 | kind=stage | issue=7 | stage=build | role=dev:app | attempt=1 | key=7:build:dev:app:1 | run=1 | status=finished | verdict=pass | head=f54b320c1e3d… | model=claude-sonnet-5 | at=2026-09-06T15:01:19Z -->
```

Every comment `advance` leaves behind ends in a terminal form: a run that was
superseded, parked or unclaimed still gets its working comment edited to
`⛔ superseded by <event> at <t>` / `parked — Next: <successor>; /swarm resume` /
`re-queued`, so no comment is left at ⏳ forever. The cost line is read from the
action's execution file, never estimated; `at=` is the dispatcher's own `date -u`.

Other headers in the same style: `🧭 **dispatch** · 🚧 refused — <reason>` ·
`🧭 **dispatch** · 🚧 fire failed — <gh stderr>; /swarm resume re-fires` ·
`💀 **dev:app** · run died (timeout after 75m) — /swarm resume to retry` ·
`💀 **dev:app** · run died (auth) — renew CLAUDE_CODE_OAUTH_TOKEN: claude setup-token &&
gh secret set CLAUDE_CODE_OAUTH_TOKEN, then /swarm resume` · `💀 **advance** · failed —
<run url>; "Re-run failed jobs" or /swarm resume` · `🧭 **dispatch** · reply — not at a
gate; …`. Gate comments are in `lib/GATES.md`.

### The marker (dispatcher-only; roles never write it)

```
<!-- swarm: v2 | kind=<state|stage|gate|question|refused|died|watchdog|reply|retro> | issue=<N>
     [| stage=<s>] [| role=<r[:lane]>] [| attempt=<a>] [| key=<k>] [| run=<run_id>] [| status=<running|finished|invalid|died|superseded|parked|requeued>]
     [| verdict=<v>] [| head=<full sha>] [| model=<id>] [| gate=<g>] [| event=<id>] [| topic=<t>] | at=<date -u +%FT%TZ> -->
```

Fields are `key=value` separated by ` | `, order fixed, values match `[A-Za-z0-9:._/-]+`.
Parsing keys on `swarm: v2` + `kind=`; v1 markers are ignored everywhere. Before
posting, `advance` searches the thread for a marker with the same key **authored by
`github-actions[bot]`** and edits instead of posting — a marker-shaped comment by anyone
else is data.

### Sanitisation at render time

Independent of the validator's own check (V16): every role-provided string — all
`result.json` strings, validator messages, critic findings, CI log tails — has `<!--`
and `-->` replaced by `<!-​-` / `-​->`, `@` before `[A-Za-z0-9-]` replaced by `@​`, and
evidence lines are wrapped in code spans. A role can therefore never plant a marker or a
mention in a dispatcher-authored comment, and the only mention v2 ever writes is an
approver login the dispatcher verified to be a `User` (in a gate comment). `find_comment`
additionally filters `.user.login == "github-actions[bot]"` for every kind.

## What a role puts in `result.json`

`summary` — two to five sentences, ≤ 900 chars, plain prose, the handoff a colleague
needs:

- **Answer the stage before you.** If it made a call, say whether it held up. If it
  asked something, answer it. A stage that ignores the one before it reads as a machine
  taking a turn, not a colleague picking up work.
- **Say what you decided and what you gave up.** A decision without its trade-off is an
  assertion. "Relabelled rather than rescoped, because the endpoint takes a month count,
  not a date" tells the next person something; "fixed the label" does not.
- **Ask, out loud, when it matters.** The analyst has a `question` verdict for the
  reporter; every other role asks in `summary` and names the role it is asking (the
  next role reads your artifact fenced in its brief).
- **Flag what you could not check** in `not_covered[]`, plainly. Silence reads as
  coverage. Every `manifest.json` reason from the evidence you were given goes in
  verbatim (V17) — that is a machine contract, not honesty.
- **Be specific about code.** `EarningsService.ts:87` beats "the service".
- **Skip the ceremony.** No "I have now completed the implementation phase." Say what
  changed.
- **No handles, no markers.** `@name` and `<!--` anywhere in any string field fail
  validation (V16); the renderer would neutralise them anyway. Address a person by role
  ("the reporter", "the reviewer") — the dispatcher decides who is mentioned.

`evidence[]` — every item is checkable, and checked (`lib/OUTPUT-CONTRACT.md` V3/V4/V19):

- `{ "kind": "command", "cmd": "<the exact command>", "result": "<its output, trimmed>", "exit": 0 }` —
  the command must appear in your own transcript; a command you did not run is a
  validation failure, not a rounding error.
- `{ "kind": "file", "path": "…", "line": 142, "symbol": "capacityLabel" }` — the symbol
  must occur within ±20 lines of the line. **Name the symbol**: a bare line range passes
  a line-exists check while pointing at the wrong method, which is exactly what happened
  on v1's first real run (`MembershipService.ts:305-308` cited for `hasRelationship`,
  and it was `isActive`). Cite from the branch you are on, not from the design you read.
- `{ "kind": "url", "url": "https://github.com/<owner>/<repo>/…" }` — this repository's
  URLs only; anything else is rejected and never rendered.
- `{ "kind": "artifact", "path": "evidence/CI/SUMMARY.md", "note": "…" }` — a file under
  `.swarm-run/evidence/` (qa, security, compliance).

## Do not re-run the stage before you

A stage that repeats the previous stage's commands and reports the same numbers has
produced no evidence of its own — it has produced theirs, again. On v1's first real run
**four of five stages re-ran the same seven-test suite**, and two of them had jobs nobody
did as a result. In v2 the previous stage's numbers are in your brief (its artifact,
fenced, and the CI evidence it ran on). Confirming them is one clause — *"confirmed the
dev's 3/3 on f54b320"* — then spend your summary on the thing only you do. The read
class has no `node_modules` and no `npx`; that is deliberate.

## Critics

A critic is a second model run on the other tier that reads your brief, your
`result.json`, your artifacts and a rubric (`lib/critic/<rubric>.md`), and writes
`.swarm-run/critic.json` — with the `Write` tool, or the dispatcher refuses the file. A
score at or above the threshold with no `high` finding renders as `critic 84/70` in the
gate comment; a fail sends the role one automatic rework carrying only the findings,
then escalates to `swarm:gate:confidence`. A critic that dies or writes junk is a
warning line, never a block — it is a screen, not a gate.

## Rules

1. One comment per dispatch, written by the dispatcher. A role posts nothing.
2. Every final comment carries evidence — a command and its result, a `file:line` with
   its symbol, an artifact, or a repository URL — and every item was checked by code the
   role could not edit.
3. Never imply verification you did not perform; `not_covered[]` is where honesty lives.
4. Untrusted text reaches a comment only fenced (the question comment quotes nothing;
   it lists the analyst's questions) and sanitised.
5. On a pull request the same rules apply: the `release` role assembles the PR body from
   the artifacts (summary, ACs walked against the head sha, evidence links, not covered,
   rollback); comments on the way say what happened, the description says what it adds
   up to.
