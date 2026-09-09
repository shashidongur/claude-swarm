# State — where the truth lives, and how to read it

Labels and the state comment are projections. The truth about an issue is one JSON
file, and it is signed.

## Where

`issues/<N>.json` on the project's orphan branch `swarm/state`, created once at install
by `lib/sh/state.sh init-branch <owner/repo>`. The branch never has CI (the project's
workflows trigger on the default branch and on pull requests only) and holds nothing but
these files, a `README.md`, and staged artifacts under `issues/<N>/pending/`.

Read it:

    gh api "repos/<owner>/<repo>/contents/issues/7.json?ref=swarm/state" --jq .content | base64 -d | jq .

Its history is the free audit trail of every transition:

    git log --oneline swarm/state -- issues/7.json     # one commit per write: "swarm #7 <transition>"

## How it is written

With the Contents API: `GET` returns the content and the blob `sha`; `PUT` carries that
`sha` back, and GitHub rejects a stale one with a conflict. That is a real
compare-and-swap. Two writers exist — `advance` after a run, and the human-command path
in `resolve` — and the CAS makes their collision a retry, never a lost update. Every
write applies one named transition (`lib/jq/transitions/<name>.jq`), each of which
begins with a precondition that errors when the state has moved on; a precondition
failure is "state moved on" (exit 5) and the caller decides, never silently. Five
conflicts in a row is a hard failure, never swallowed.

## Why it is signed

Every write sets `sig = HMAC-SHA256(SWARM_STATE_KEY, jq -S -c 'del(.sig)')`, and every
read verifies it before trusting a byte. The reason: the write class holds a repo-wide
App token and unrestricted Bash, so a role *can* `git push origin HEAD:refs/heads/swarm/state`
or `PUT` through the Contents API a forged `status: queued, next: release` and let the
watchdog run it past the human gates. Commit author and GitHub's signature are both
forgeable through the Contents API's `author` field; a keyed MAC held only by the
dispatcher's LLM-free jobs (`resolve`, `advance`, `refuse`) is not. Staged artifacts are
listed in the signed state with their `sha256`, so they cannot be swapped either.

**`blocked:perimeter` on a signature** means a state file was found whose `sig` is
missing or does not verify. The comment names the offending commit
(`git log -1 swarm/state -- issues/<N>.json`). Look at it before anything else: either
someone rotated `SWARM_STATE_KEY` without running `state.sh resign-all`, or a run wrote
to the state branch by a path it should not have. The watchdog never fires from an
unverified file.

## What the fields mean (the ones a human needs)

| Field | Meaning |
|---|---|
| `stage`, `status` | where the issue is; `status ∈ running \| routing \| queued \| evidence \| gate \| blocked \| parked \| dropped \| done` |
| `path`, `path_source` | `full` or `short`, decided by `triage`, escalated by the analyst, or set by `/swarm path` |
| `current` | the dispatch that holds the claim: `role`, `attempt`, `key`, `run_id`, `comment_id`, `started_at`, `base_sha` |
| `next` | when `queued`: what fires next and whether it has been fired (`fired_at`, `fired_by`, `fired_run_id`, `not_before`) |
| `gate` | when `gate`: `name`, `since`, the gate comment id, `reminded_at` |
| `evidence.pending` / `seen` / `fires` | the evidence run being waited on; every CI/evidence conclusion by head, workflow and event; fire counts per workflow |
| `branch`, `head`, `pr` | the integration branch, the last head a write role pushed, the PR number |
| `merged_at`, `merged_pr`, `merge_sha`, `merged_by` | set once by the merge; retro fires at most once per merge |
| `pending_artifacts` | files staged on `swarm/state` that the next write role's first commit lands; cleared only when seen on a pushed head |
| `rework` | `spent` / `budget` (5), `reset_at`, and the log of every rework edge |
| `stages.<stage>` | `status`, the `attempts` counter per role (monotonic; the source of attempt numbers), critic score, approval |
| `dispatches[]` | append-only, capped at 60 (oldest folded into `totals`): every run with its key, run id, verdict, model requested and actual, cost, turns, minutes, validation errors and a redacted `last_text` |
| `totals` | `cost_usd`, `turns`, `runner_minutes` (role runs), `overhead_minutes` (the dispatcher's own jobs), `wakeups`, `reworks` |
| `swarm_sha`, `pipeline_sha`, `config_sha` | the swarm code pinned for this issue (re-pinned only by `/swarm redo`), the routing version, the config blob at the last event |
| `flags` | `hands_off` (set by label or command, cleared only by hand), `v1_history` (v1 comments present; never parsed) |
| `memory` | the swarm-repo pull request opened at retro, or the patch artifact when it could not be |
| `refusals`, `log` | one refusal reply per login per day; the last 50 human/machine events |

Full schema: `lib/schema/state.schema.json`.

## The labels (projection of status)

`lib/sh/labels.sh project` computes the desired set from state and reconciles **only
inside the managed namespaces** `swarm:` (minus the human-owned set), `blocked:`,
`size:`, `area:`, `prio:` and the three type labels. **Human-owned, never removed by
projection:** `swarm:hands-off`, `swarm:control`, `swarm:halt`, `swarm:halt-pipeline`.
`swarm:ready` is consumed explicitly by `start`, never by projection.

| State | Labels |
|---|---|
| `stage = X` (status ∉ done/dropped) | `swarm:<X>` (triage, requirements, design, architecture, build, test, security, release, retro) |
| `status = gate`, `gate.name = G` | `swarm:gate:<G>` (requirements, architecture, release, question, confidence, budget) |
| `status = evidence` | `swarm:waiting:evidence` |
| `status = queued` or `routing` | (no label; the state header says "queued — fired <at>, run <id or 'not yet started'>" / "routing") |
| `status = blocked` | `swarm:blocked` + one `blocked:<reason>` (agent-output, budget, runaway, evidence, stalled, fire, injection, duplicate, conflict, bad-handoff, perimeter, auth, model) |
| `status = parked` | `swarm:parked` |
| `status = dropped` | `swarm:dropped` (stage label removed) |
| `status = done` | `swarm:done` (stage label removed) |
| `path = short` | `swarm:short` |
| `flags.hands_off` | `swarm:hands-off` (set by command or by hand; cleared only by hand) |
| triage output | `bug` / `feature` / `chore`, `size:S\|M\|L\|XL`, `area:<lane>\|both`, `prio:P0..P3` |
| sub-issues | `swarm:lane` + `swarm:hands-off` (never dispatched: the veto guard refuses any dispatch on a hands-off issue even if a future guard change forgets `swarm:lane`) |

Exactly one `swarm:<stage>` label at a time, at most one `swarm:gate:*`. A hand-added
stage label on an issue with no v2 state gets one reply and changes nothing: labels are
written by the dispatcher; add `swarm:ready` or comment `/swarm start`.

## The state comment

One `kind=state` comment per issue, posted at `start` under `github.token` and
re-rendered after every successful write: a header for humans (`lib/GATES.md` shows it)
and a `<details>` block with the JSON. It is never parsed back. Deleting it costs
nothing — the next event re-posts it.

## When they disagree

**The file wins.** Labels can be edited by hand, the comment can be deleted, a
projection can lose a race; the signed file cannot. `/swarm status` re-renders the
comment and re-projects the labels from the file, and replies with one line saying
where the issue is and what it is waiting for. If the *file* looks wrong, its git
history says which transition wrote what, and `/swarm resume`, `/swarm redo <stage>` or
`/swarm park` are the levers — never a hand edit of the branch, which would fail the
signature check and block the issue on `blocked:perimeter`.

## Tools

`lib/sh/state.sh` is the only writer. Beyond `read`/`write <issue> <transition>` it has
`apply <json|-|null> <transition> [--arg …]` (apply a transition offline, without
reading or writing GitHub — how `start` builds the initial document before `create`),
`create <issue> <json>` (exit 7, printing the existing verified document, when the file
already exists — the duplicate-start guard reads it), `sync-comment <issue>` (re-render
the state comment and record its id), `stage-pending`/`copy-pending`/`clear-pending`
for staged artifacts, `next-key`, `month-totals`, `billing-used` and `resign-all`. A
`write` whose transition changes nothing skips the PUT. `SWARM_STATE_RACE_HOOK` is a
test-only hook (honoured only under the conformance shim) that runs a command between
the read and the PUT so the harness can inject a genuine concurrent writer and prove
the CAS retry keeps both writers' changes.

## Key rotation

`SWARM_STATE_KEY` is a repository secret (`gh secret set SWARM_STATE_KEY --body
"$(openssl rand -hex 32)"`). Rotating it invalidates every in-flight signature. Right
after rotating, before the next event, a human with the new key in the environment runs

    SWARM_STATE_KEY=<new key> lib/sh/state.sh resign-all <owner/repo>

which re-reads every `issues/*.json`, re-signs it, and writes it back through the same
CAS. Until that has run, every event on an in-flight issue reports `blocked:perimeter`.
