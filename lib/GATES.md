# Gates and commands — what a human types

Three gates, three wait-states, one grammar. A gate is a comment (or a merge), never a
job that waits: nothing sits on a runner for days, and nothing times out because the
owner was asleep. Every wait-state comment's last line is the command to type, and
`/swarm approve` needs no argument.

## The grammar

First non-empty line of a comment on the issue (or on its PR's conversation, or the body
of a PR review), after trimming:

```
/swarm <verb> [args…]
verb ∈ { start, approve, reject, resume, redo, skip, park, drop, hands-off, path, status }
start      [full|short] [force]                                  # force overrides the monthly brake (G31)
approve    [requirements|architecture|confidence|budget]         # optional gate name must match state.gate
reject     <free text reason, ≥ 3 chars>                         # at any gate; stored fenced and fed to the rework target
resume                                                           # after blocked/parked/died/fire-failed/stalled; at question gate = proceed with assumptions
redo       <stage> [free text reason]                            # stage ∈ pipeline stages; from a non-running status; re-pins swarm_sha
skip       <stage> [free text reason]                            # stage ∉ {triage, build, release, retro}; records skipped_by_owner and advances
park
drop
hands-off
path       full|short                                            # owner override of triage
status
```

Regex (bash ERE on the first line): `^/swarm[[:space:]]+([a-z-]+)([[:space:]]+(.*))?[[:space:]]*$`.
Unknown verb → reply listing the verbs. Everything after the first line is data
(`lib/GUARD.md`). `approve release` is not a command (merge the PR) → the reply says so.

Adding the label `swarm:ready` is the label-shaped spelling of `/swarm start` (same
approver rule). Merging the PR — as an approver — is the approval of gate 3.

## Identity

- `github.event.sender.type == 'User'` (bots never command).
- Login ∈ `approvers.<gate>` if set, else `approvers.default`, else
  `[github.repository_owner]` when `gh api users/<owner> --jq .type` is `User`; on an
  org-owned repo with no config the command is refused with "configure approvers in
  .github/swarm.yml". At `start`, every configured login is verified once to be a `User`
  (recorded in `log`).
- `approve`/`reject` use the gate-specific list; `budget` uses `approvers.default`; every
  other verb — and the `swarm:ready` label — uses `approvers.default`.
- The merge that closes gate 3 must be performed by a login in `approvers.release`
  (G35); the release gate comment names the list.
- Answers at `swarm:gate:question` are accepted from the issue author (if a User and
  `reporter_may_answer`) or any approver; they need no `/swarm` prefix. A reply that
  starts with `/swarm` is a command, not an answer.
- Refusals are replied once per login per issue per day (G38); a non-approver cannot
  spend the minute budget one comment at a time.

## Semantics and admissibility

| Verb | Admissible when | Effect |
|---|---|---|
| `start` | no state; or `parked`/`blocked`/`dropped` | monthly brake (G31); create state (path forced if given) + pin `swarm_sha`, fire `triage` (or `requirements` when a path is forced); on an existing parked/blocked/dropped state behaves as `resume`; on a state created < 5 min ago by another `start` → reply "already started" (G28) |
| `approve` | `status = gate`, gate ∈ {requirements, architecture, confidence, budget} | record approver + time in `stages[<stage>].approved`; `totals.wakeups++`; fire the stage after the gate; at `confidence` fire the stage after the escalated one; at `budget` raise `limits.cost_usd_per_issue` for this issue by one envelope and fire the queued `next` |
| `reject` | `status = gate` (any gate incl. `release`) | `rework.spent = 0`, `rework.reset_at`; fire the gate's rework target with the fenced reason: `requirements → analyst`, `architecture → architect`, `confidence → the escalated role`, `question → analyst`, `release → analyst` in feedback mode (returns `hints.redo: <stage>`; `advance` fires that stage); `budget → park` |
| `resume` | `blocked`, `parked`, `gate:question`, `queued`, `evidence` | clear `swarm:blocked`/`blocked:*`/`swarm:parked`; then by case: `blocked:fire` → fire `next`; `blocked:stalled` with a completed run job for `current.run_id` and a handoff artifact → fire `reason=finalize`; `parked` → fire `next` if set, else `current` at attempt+1; other `blocked` → re-fire `current` at attempt+1; `queued` → fire `next` unless `next.fired_at` is recent and its run is alive (reply "already fired: <run url>"); `evidence` → re-query GitHub for the pending run; `question` → fire `analyst` with "no answer; proceed on stated assumptions" |
| `redo` | any status except `running`/`routing` (→ reply "wait for the stage to finish or `/swarm park` first") | `rework.spent = 0`; set `stage`; re-pin `swarm_sha`; fire its first role at attempt+1 with the reason; later stages reset to `pending`; branch/PR kept |
| `skip` | not `running`; stage on the path, ∉ {triage, build, release, retro}; stage index ≥ current | `stages[<stage>].status = skipped_by_owner` (+ reason); if it is the current stage, advance to the next stage as if passed; a gate after the skipped stage is still enforced |
| `park` | any except `done`/`dropped` | `status = parked`; a running stage finishes its job, `advance` records everything and fires nothing; sub-issues untouched |
| `drop` | any | `status = dropped`; close sub-issues with a comment; PR left open with a comment; branch kept (never destroy work) |
| `hands-off` | any | `flags.hands_off = true`, label; the machine ignores the issue until the label is removed by hand; `status` still answers |
| `path` | `triage` done and stage ≤ `requirements` | `path`, `path_source = owner`; at `gate:requirements` becoming short dissolves the gate and skips `design`/`architecture` |
| `status` | always | re-render the state comment; reply one line: "`<stage>` · `<status>` · next: <what the human should do or what the machine is waiting for> · $<cost> · <min> min (+<overhead>) · <run link>" |

Every accepted command CAS-writes the state, re-renders the state comment and posts a
one-line acknowledgement reply (`github.token`, silent, skip-if-exists per event id).
Refused commands reply with the reason (G17), once per login per day (G38). A command
that is not admissible in the current status is explained, not swallowed: "not at a
gate; running `dev:app` since 10:41 — <run url>".

## The gate comments

Rendered by `advance`, one per gate entry (keyed `gate:<name>:<key>`):

```
🛎️ **gate · requirements** — @<approver login>, your call.

Requirements for #7 are on the branch: docs/swarm/7/requirements.md (7 ACs, refs CAP-…).
Critic score 84/70: grounded, testable; one assumption flagged about capacity limits (AC-7-5).
Cost so far $1.90 · 9 runner minutes.

Reply `/swarm approve` to continue to design, or `/swarm reject <why>` to send it back to the analyst.
<!-- swarm: v2 | kind=gate | issue=7 | gate=requirements | key=7:requirements:analyst:1 | at=2026-09-06T10:03:40Z -->
```

The `@<login>` is an approver login from config verified to be a `User` — the only
mention v2 ever writes. The other gate and wait-state comments follow the same shape:

- **`architecture`** — lists the five architect artifacts and the threat-model verdict,
  the critic score; `/swarm approve` continues to build, `/swarm reject <why>` returns
  to the architect.
- **`release`** — links the PR: "merge PR #9 to release (the merge must be made by
  <approvers.release>); `/swarm reject <why>` or `/swarm redo <stage> <why>` otherwise".
- **`question`** — addresses the issue author (`@<author>` only if `user.type == User`,
  else the default approver), lists the questions, "reply in plain text — your first
  comment resumes the analyst; anything you add before it starts is included; a comment
  while it runs is ignored".
- **`confidence`** — lists the critic findings and offers `/swarm approve` (push
  through) or `/swarm redo <stage> <why>`.
- **`budget`** — shows the sum, the cap and the next dispatch's estimate, and offers
  `/swarm approve` (raise the cap by one envelope), `/swarm park` or `/swarm drop`.

After `gate_reminder_days` (3) at any gate the watchdog posts one reminder, then edits
the same comment every 7 days. Nothing else happens while a gate waits — labels, state
file and state comment persist, and `/swarm approve` picks up where it stopped.

## The state comment header

One `kind=state` comment per issue, posted at `start` and re-rendered after every state
write. Its header is what the owner reads on a phone:

```
🧭 **swarm** · build · running `dev:app` (attempt 1) · $14.20 · 61 min runner (+9 overhead) · rework 1/5 · cap $75

- [x] triage — short? no (feature, M, both) · haiku · $0.04
- [x] requirements — approved by @<login> 2026-09-06T10:12Z · critic 84
- [x] design — a11y pass
- [x] architecture — approved 2026-09-06T14:40Z · critic 79
- [ ] build — planner ✓ · test-writer ✓ (PR #9 draft) · dev:api ✓ · code-review:api ✓ · **dev:app ⏳** · code-review:app
- [ ] test · [ ] security · [ ] release · [ ] retro

Branch `claude/issue-7-live-session-capacity` · head `f54b320` · PR #9 · artifacts `docs/swarm/7/` · state `swarm/state:issues/7.json` · swarm `v2@ab12cd3`
Last run: https://github.com/…/actions/runs/1
```

The machine-readable state follows in a `<details>` block; `lib/STATE.md` explains it.

## Gate 3 counts only when an approver merges

The write class holds an App token with contents and pull-requests write on the whole
repository, and the tool deny-list stops `gh pr merge` and `git push origin main` — not
`gh api --method PUT …/pulls/9/merge`, `curl` against the API, or a plus-push to `main`.
So gate 3 is enforced where it can be verified: when the PR closes as merged, the
dispatcher checks `merged_by.type == User ∧ login ∈ approvers.release`. Any other merger
— `claude[bot]`, a stranger, a bot — is `blocked:perimeter`: the comment names the merge
commit and the `git revert -m 1 <sha>` a human runs, and **no retro fires, no branch is
deleted, no sub-issue is closed, the issue does not become `swarm:done`**. The same
check refuses a merge by a `User` who is not on the release list: the gate is *who*,
not *that*.
