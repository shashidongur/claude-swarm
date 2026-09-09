---
name: v2-design
description: Pipeline v2 in one page — the seventeen decisions with their rationales, the open risks and how each is closed, and what the three adversarial reviews changed
metadata:
  type: decision
---

Synthesised 2026-09-06 from three candidate designs (human gates and cost first; a
deterministic dispatcher with a probe, a perimeter and pipeline conformance; a
minimal-delta design with an evidence manifest, a portability grep and reconciliation
glue), corrected on every point the judges agreed all three got wrong, then hardened
against three adversarial reviews. The spec is 17 sections; `lib/*.md` and
`PLAYBOOK.md` on branch `v2` are its human-readable projection.

## What v2 optimises, in order

1. **No silent stall, ever** — every v1 stall was an LLM-written handoff or an
   unanswered machine event; in v2 the LLM writes nothing that routes.
2. **Fewest human wake-ups** — three on the full path, one on the short path.
3. **Runner minutes and dollars are budgets, not estimates.**
4. **Verified before built** — a ten-minute probe settles the runtime assumptions.
5. **Nothing in the owner's plan is dropped** — every stage, agent and evidence type
   maps to a row of the routing table or a file in the manifest.

## The decisions

| ID | Decision | Why |
|---|---|---|
| D1 | Baton = `gh workflow run <stub> -f issue -f stage -f role -f key -f reason` from `advance` under `github.token`, **after a CAS claim of the fire** (`next.fired_at/fired_by`), then fire-and-verify by the key in the stub's `run-name`; no verified run → `blocked:fire`, red job. Mentions retired. | The one github.token event GitHub documents as firing; claiming first closes the queue-lag window in which two writers both fire; a lost fire left to the twice-daily watchdog is a 12-hour silent stall, so it is made loud. |
| D2 | State = `issues/<N>.json` on the project's orphan branch `swarm/state`, written via Contents-API `PUT`-with-`sha` compare-and-swap and **signed** (HMAC-SHA256 with `SWARM_STATE_KEY`); one `kind=state` comment is the rendered projection; labels are the projection of status; swarm code pinned per issue (`swarm_sha`); dispatch records keyed `(key, run_id)`; attempts are monotonic counters. | Two writers exist and a comment edit has no CAS; a role with a repo-wide App token can push a forged `queued` state the watchdog would execute; commit author and GitHub signature are forgeable through the Contents API's `author` field, a keyed MAC held only by LLM-free jobs is not. |
| D3 | Critic = second `claude-code-action` step in the same run job for read-class roles, a separate read-only `critic` job for write-class roles; other model tier; default-on for `requirements`, `architecture`, `release`; `critic.json` deleted before the critic and accepted only when the critic's own transcript wrote it; one auto-rework then `swarm:gate:confidence`. | A same-job step costs no runner for read roles; in the write job a critic reading role-authored text would hold the App token; a role must not pre-write its own score. |
| D4 | `result.json` validated in the run job (jq + nineteen reality checks) to drive one retry fed only the validator's errors; **re-validated authoritatively by `advance`** from fresh checkouts; then `blocked:agent-output`; a valid result after a `--max-turns` overrun counts as finished; every step after `begin.sh` gated on its success. | v1's "green run, no handoff" becomes a validator failure that usually self-heals; the in-job validator, transcript and handoff live in a workspace the role controls; a run that never claimed must never run a model. |
| D5 | Gate = `/swarm approve` / `/swarm reject <why>` first line by a `User` in `approvers` (default: repo owner on user-owned repos); `swarm:ready` needs the same approver; gate 3 = merge **by an approver** (G35); `budget` wait-state beside `question` and `confidence`. | Labels and comments are the only human signals a Free-plan private repo offers; the App token can plausibly merge its own PR, so who merged is checked; a cost cap that kills an issue mid-review is worse than one that asks. |
| D6 | Sub-issues for tracking only (`swarm:lane` + `swarm:hands-off`); lanes sequential on the parent thread on one branch; the test-writer opens the draft PR at its first push; after that only roles push and dispatcher artifacts are staged (sha256 in the signed state), **copied** into the next write role's first commit, cleared only once seen on the pushed head. | Sequential lanes remove the join problem; a role-opened PR keeps CI running on every commit; a github.token push onto an open PR leaves CI in approval-required; a "take" a blocked role never pushes would leave `release` refused forever. |
| D7 | Evidence workflows = project-side `workflow_dispatch(issue, ref, key)` with `run-name` carrying the key, `permissions: contents: read`, no secrets; fired by `advance` ≤ `evidence_fires_per_issue` (2) per workflow; consumed on `workflow_run: completed`, recorded at any status keyed `(head, workflow, event)`, reconciled against `actions/runs?head_sha=` before any wait. | No runner waits; CI routinely finishes while the write role is still running; a rework loop must not re-run the emulator per head; a branch-controlled workflow with a write token could push to `main` silently. |
| D8 | Tiers in `pipeline.yml` with `must_differ_from` conformance-checked; `run-read` (`github_token` override, `contents: read`, no `id-token`) vs `run-write` (App token) by class; no job with a model step holds `SWARM_TOKEN`/`SWARM_STATE_KEY` (swarm tree as an artifact; `persist-credentials: false`); `Write/Edit` confined by a path hook, `Bash` screened by a command hook; protected paths include `.claude/**`, `CLAUDE.md`, `.mcp.json` and the CI-gate files; `claude[bot]` activity outside the branch, a rewritten history or a changed gate script → `blocked:perimeter`; transcripts redacted; actual model recorded. | The job token is the only real perimeter on Actions; a persisted PAT in `.git/config` was a pipeline-takeover path; planted project settings are loaded as trusted configuration by the next role; a dev that can edit the baseline can make CI green. |
| D9 | Retro emits `memory[]` (new files only under `postmortems/`, `adrs/`, `gotchas/auto/`, `runs/`); `advance` commits them on a branch of claude-swarm and **opens a pull request** with `SWARM_TOKEN`; machine-written memory is loaded fenced until promoted; failure → patch artifact and a visible line. | An LLM reading attacker-influenced text must not write unfenced permanent instructions; a runtime path must never write to the branch the dispatcher executes from without a human in the loop. |
| D10 | Stage 8 `release` (PR body assembled and PR readied by the role; strong critic in its own read-only job; gate = merge by an approver); stage 9 `retro` (post-mortem, ADR pointer, auto gotchas, metrics as a memory PR; sub-issues closed, branch deleted, `swarm:done`) — fired at most once per merge. | The merge is the third expensive decision and needs an evidence-assembled PR; a retro that writes memory is how "agents learn from earlier runs" becomes real; a redelivered `pull_request.closed` must not run it twice. |
| D11 | Runaway = dispatches recorded in state in the last hour ≥ 10; rework budget = `rework.spent` (5, reset by owner reject/redo); per-issue USD cap (75, opus at 2.5× sonnet) as a **wait-state**; monthly minutes/USD brake (1,500 / 200) at `start`, before every write-role dispatch and before evidence fires, fed by the billing endpoint when `SWARM_TOKEN` can read it. | v1 counted its own noise runs and any owner chatter reset the budget; a $40 cap terminated a healthy issue during its second review rework; the swarm's own sums miss the owner's workflows, and exhausting the Free quota freezes every workflow in the repository. |
| D12 | Mobile jest gates on "no failures outside `jest.baseline.json`", recorded and checked in coverage mode with `--forceExit` (91 failing vs 52); jest's exit code tolerated; coverage by `scripts/coverage-check.js` with thresholds re-measured under the shipped config; `npm audit` and Semgrep baselined; gitleaks never; gate files protected. | A baseline recorded in a different mode reports 39 phantom failures on day one; a red `test:ci` ends the step before the baseline check runs; unbaselined scanners are red on every branch forever. |
| D13 | Triage picks `short` only for `size:S` ∧ `type ∈ {bug, chore}` ∧ one lane; short skips design, architecture, planner, gates 1–2, critics (except release), the emulator and the security workflow; security role on short only when CI's audit/SAST counts changed; compliance only on `sensitive_paths`; analyst may escalate, owner may `/swarm path`. | The owner's short-path intent without losing tests, scans, review or the merge gate; a "no new findings" security report on every chore is 20 billed minutes for nothing. |
| D14 | product-owner → `triage` + `analyst` + `release`; designer → `ux`; implementer → `dev` (lane-parameterised, project specialist layered); reviewer → `code-review`; test-engineer → `test-writer` + `qa`; explorer/groomer/warden kept on disk, not installed. | The v1 methods that worked (reviewer, architect) are kept verbatim while each v2 stage gets a single-purpose role the pipeline can validate. |
| D15 | Analyst `verdict: question` → questions posted to the issue author, `swarm:gate:question`; the first plain comment by the author or an approver consumes the round and resumes the analyst at attempt+1 with **every** later author/approver comment fenced; two rounds, then gate 1 with assumptions. | The reporter's reply is the resume, no grammar to learn, a bounded loop cannot stall, a split answer must not burn a round. |
| D16 | Retro fires on `pull_request: closed && merged` on a `claude/issue-<N>-*` head, mapped by branch prefix, cross-checked against `state.pr` and the `Swarm-Issue: #N` trailer; `merged_by` must be an approver `User`; `pr-merged` admissible from any status, idempotent on `merged_at`, dissolves gates and pending fires, never re-fires a stage. | The owner merges red or mid-stage PRs; v1's "labels left at swarm:pr forever" must not return by another road; a redelivered webhook must not spawn a second retro. |
| D17 | Step-level `timeout-minutes` + `continue-on-error` on every action step, `if: always()` audit upload; `advance` classifies `max-turns`/`timeout`/`cancelled`/`error`/`auth`/`ratelimit` — only for the run that holds the claim; one auto-retry for `max-turns`/`error` at attempt 1; `ratelimit` re-queues with a back-off; `auth` → `blocked:auth` naming the renewal command; a failed `advance` is `blocked:stalled` and `/swarm resume` finalises from the stored handoff. | The transcript of exactly the runs that die must be captured; a timeout must not be retried blindly at full cost; an expired token should cost one note; an exhausted plan must not be retried into the same wall; a finished run whose finaliser died must not be thrown away. |

## Open risks, and how each is closed

| # | Assumption | If wrong | Closed by |
|---|---|---|---|
| R1 | The chain actor of a github.token `workflow_dispatch` is covered by `allowed_bots` | no baton after triage | probe run 2: `github-actions[bot]`, accepted with `allowed_bots: "github-actions,claude"` |
| R2 | `github_token: ${{ github.token }}` skips OIDC and bounds `gh`/`git push` by the job permissions | read-class perimeter is only tools + hooks + G29 | probe run 2: 200 / 403 / push refused (403) |
| R3 | `--model <id>` is honoured under the OAuth token | reviewer ≠ author by instance only | probe run 2: `modelUsage: ["claude-opus-5"]` |
| R4 | Contents-API `PUT` with a stale `sha` conflicts; the orphan branch can be made via the Git Data API | LEASE-style ref CAS instead | branch created (48a80b0); run 2's CAS test was invalid (identical content → identical blob sha), re-run with distinct content in run 3 |
| R5 | The execution file survives a `--max-turns` overrun / a step timeout | no transcript for died runs (tolerated: `present:false`) | run 2: exists after max-turns (`subtype: error_max_turns`, `is_error: true`); timeout re-tested in run 3 |
| R6 | `if: always()` steps run after a step timeout | audit upload moves to an always-job | run 3 |
| R7 | `fromJSON(...)` timeouts on steps/jobs, `settings:` as a file path, two PreToolUse matchers | constants; Bash hook dropped | actionlint; first dispatch |
| R8 | `workflow_run` fires for dispatch-started default-branch runs with `display_title = run-name` | evidence never resumes | hand run at switch-on; fallback documented in `templates/evidence-workflow.md` |
| R9 | `${{ inputs.* }}` is empty, not an error, on non-dispatch events | the reusable call fails | actionlint; `\|\| ''` fallback |
| R10 | `gh issue create --parent/--type` on a user-owned repo | flat sub-issues | `advance` falls back |
| R11 | The App token can `gh pr create/edit/ready` | `advance` flips draft with github.token | smoke run |
| R12 | mikefarah `yq` v4 on `ubuntu-latest` | PyYAML fallback | `config.sh` |
| R13 | RN debug APK builds cold in ≤ 15 min with the NDK download | walkthrough > 45 min → `blocked:evidence` | hand run; cold time into `conventions.md` |
| R14 | Regex text selectors drive the mock-mode app past the splash | E2E vacuous; qa classifies `environment` | hand run |
| R15 | ≈ 4 full issues/month at the 1,500-minute brake | fewer | first two retros |
| R16–R19 | Semgrep registry reach, ZAP list manageable, osv reusable callable, coverage thresholds hold | slow/red jobs; adjust | first CI runs |
| R20 | `SWARM_TOKEN` can push a branch and open a PR on claude-swarm | patch artifacts (designed) | smoke run retro |
| R21 | The `--log-failed` patterns catch `auth` and `ratelimit` | classified `error` | extend when seen |
| R22–R23 | State comment readable on a phone; ≈ 5.5 billed min/hop | keep header ≤ 25 lines; rows off | after two issues |
| R24–R27 | Expression functions in job `if:`; reporter never types `/swarm` first; sequential lanes; single collaborator | conformance + smoke | — |
| R28 | The App token reaches only the project repo | narrow the installation | probe `write` job — **unanswered**: the OIDC exchange refuses a workflow file not identical on the default branch; measured once the stub is on `main` |
| R29 | The App token cannot merge a PR / push workflow files | gate 3 detective (G35 + revert); `.github/**` on a branch → `blocked:perimeter` + `swarm:halt` advice | same |
| R30 | Headless runs apply the checkout's `.claude/settings.json` and `.mcp.json` | restore from merge base is load-bearing | run 2: **they do** — the restore is load-bearing |
| R31–R35 | Activity API latency; billing endpoint readable with Plan: read; provenance vs HMAC; `download-artifact` by `run-id`; `advance` survives a pending-job cancellation | ls-remote fallback; state sums; HMAC stays; resume re-runs the role; watchdog backstop | first runs |

Residual, accepted: for the write class the transcript, `validation.json` and
`perimeter.txt` are role-writable (the merge-gating checks are re-derived from GitHub);
for the read class `node`/`find`/`npm run` are arbitrary execution in a read-only job.
Explicitly not verified and always said so: iOS, media playback, production auth and
real receipt verification, DAST until an OpenAPI spec exists, visual regression until
baselines exist.

## What the adversarial reviews changed

**Liveness / idempotency.** Every post-`begin` step gated on `begin`'s outcome (a lost
claim runs no model). Advance order made the contract: `dispatch-finished` → comment →
`route` (CAS `status == routing`) → fire, plus an `if: always()` reconcile step. Evidence
recorded at any status and reconciled against GitHub before any wait. A fire with no
verified run is an error (`blocked:fire`), never a log line. Unclaimed and
pending-cancelled runs re-queued, never classified as died. Claim before fire; `start`
racing itself replies; `resume` at a recent live fire replies. `pr-merged` idempotent on
`merged_at`. Attempts as monotonic counters. Pending artifacts copied, never taken. One
CI run per push (push trigger dropped). A failing `advance` is a red issue with a
`finalize` path from the stored handoff. `park` during a running stage keeps the work.

**Security.** No secret in any job with a model step (swarm tree as an artifact;
`persist-credentials: false`; `SWARM_TOKEN` only in `resolve`/`advance`; code pinned per
issue; memory via PR). Gate 3 = merge by an approver, with the Activity API and a
command hook behind it. The state file is signed (author/signature rejected as the
anchor — forgeable via the Contents API `author` field; confirmed in probe run 2 that
any API writer gets a verified signature). `run-read` stays read-only: the claim and the
working comment moved into `resolve`. Write-class critics in their own job. `advance`
re-validates authoritatively; `critic.json` accepted only from the critic's own `Write`.
Path grammar on every path field. `.claude/**`, `CLAUDE.md`, `.mcp.json` protected and
restored from the merge base. Memory split curated/fenced. Project workflows never hold
a write token. Render-time sanitisation; transcripts redacted; CI gate configuration
protected and diffed.

**Cost / CI.** The mobile test step tolerates jest's exit so the baseline check runs;
`coverageThreshold` out of jest configs; audit and Semgrep baselined like jest, gitleaks
never; the budget envelope recomputed (≈ 5.5 billed min/hop; ≈ 4 full or 8 short issues
a month); cost cap 40 → 75 and a wait-state; `ratelimit` class with a back-off; the
monthly brake reads the billing endpoint; evidence fire cap; DAST honest (skipped with
a manifest reason until an OpenAPI spec exists); regex selectors escaped; `npm ci`
removed from the scan job; caches keyed on version only, the walkthrough budgeted cold.

**Rejected, with reasons.** Concurrency-group dedupe of two CI runs (a cancelled
duplicate still costs minutes and emits an event — the trigger was removed instead);
`paths-ignore: docs/swarm/**` on CI (the release push touches only docs and its head
needs a CI conclusion); carrying scans outside the CI conclusion (a real secret must
stay red); commit provenance as the state anchor (forgeable); a dedicated read-only PAT
(no gain over resolve-claims); memory appends with marker idempotency (retro never
appends); `persist-credentials: false` while still checking out the swarm with a token
in run jobs (superseded by the artifact).

## Probe lessons that changed the code after the spec

- `gh workflow run` / `gh run list` / `gh run view` need `-R "$REPO"` in any job without
  a checkout (`fatal: not a git repository`); one billed minute to learn.
- `exec-stats.sh` must read `subtype` / `is_error` from the result record for the
  max-turns classification (`subtype: "error_max_turns"`).
- The App-token exchange only works when the calling workflow file is identical on the
  default branch: write-class stages cannot be exercised from a feature-branch stub, and
  the switch-on order merges the stub first.
