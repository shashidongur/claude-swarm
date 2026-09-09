---
name: claude-code-action-facts
description: What anthropics/claude-code-action actually does with tokens, actors, settings and transcripts — read from its source and confirmed by the v2 probe; the perimeter design rests on these
metadata:
  type: reference
---

Facts about `anthropics/claude-code-action@v1` that the v2 dispatcher's perimeter
depends on. Each was read from the action's source or observed in a probe run
(2026-09-08, runs 34258103147 → 34258112756 on the first project); re-verify against the
action's changelog when bumping its version.

## Tokens

- **The App installation token is minted per action step and revoked at the end of
  the step** (`Revoke app token`, `if: always()`). No later step in the same job can
  push as `claude[bot]`. Consequences: staged artifacts must land *inside* the role's
  own push (so `begin.sh` commits them locally before the role step); the retry step
  re-exchanges OIDC and gets a fresh token; a step after the role cannot "finish the
  push" for it.
- **`github_token:` input = `OVERRIDE_GITHUB_TOKEN`**, returned before any OIDC exchange
  is attempted. A job that passes `${{ github.token }}` therefore needs no `id-token:
  write`, and the role's `gh` and `git push` are bounded by the job's `permissions:`.
  Probe: the action logged `Using provided GITHUB_TOKEN for authentication` (revoke
  step skipped); inside the role `GET …/issues → 200`, `POST …/comments → 403
  Forbidden`, `git push origin HEAD:refs/heads/probe-should-fail → remote: Write access
  to repository not granted (403)`.
- **The OIDC → App-token exchange refuses a calling workflow file that is not identical
  on the default branch** (`Workflow validation failed. The workflow file must exist and
  have identical content to the version on the repository's default branch`). Every
  write-class job depends on the exchange, so a write-class stage cannot run from a
  feature-branch stub; the read class (override token) runs from any branch. Merge the
  stub before the first write role.
- `actions/checkout` persists its token in `.git/config` unless `persist-credentials:
  false`. v1 checked out the swarm repo with `SWARM_TOKEN` in the same job as the role
  step and left it there; v2 ships the swarm tree as an artifact and every project
  checkout sets `persist-credentials: false`.
- Commits made with `github.token` through the Contents API carry author
  `github-actions[bot]` and `verification.verified: true`. Any API writer gets both,
  which is why neither is the state file's trust anchor (the HMAC is).

## Actors

- Agent mode always runs `checkHumanActor`, so the actor of every dispatch must be
  covered by `allowed_bots`. A `workflow_dispatch` fired by `gh workflow run` under
  `github.token` runs with `github.actor = github-actions[bot]` and
  `triggering_actor = github-actions[bot]`; `allowed_bots: "github-actions,claude"`
  covers it (probe: `Actor github-actions[bot] is in allowed_bots list, skipping human
  actor check`).
- Agent mode always runs `configureGitAuth`: `origin` is rewritten with whichever token
  is active. With the override token in a read-only job that push is refused by the
  remote — the perimeter is the job's permissions, not the rewrite.

## Turns, transcripts, settings

- A `--max-turns` overrun **fails the step** even when the model wrote a valid result
  before it (`##[error]Execution failed: Reached maximum number of turns (N)`); the
  execution file still exists (`$RUNNER_TEMP/claude-execution-output.json`, the
  `execution_file` step output is set) and its result record reads `{subtype:
  "error_max_turns", is_error: true, num_turns: N+1}`. `advance` treats a valid result
  after an overrun as finished and classifies `max-turns` from `subtype`/`is_error`,
  not from the step outcome alone. Every action step therefore carries
  `continue-on-error: true` and the audit upload is `if: always()`.
- **The execution file is unmasked.** The job log masks secrets; the JSON file does not,
  and a role can `env` its way into it. `redact.sh` runs over every transcript before
  upload, over `previous-attempt.md`, over `last_text` in state and over every string
  rendered into a comment.
- `show_full_output: false` (the default) hides the stream but the execution file is
  written regardless (`Log saved to …/claude-execution-output.json` appeared with it
  off). v2 keeps `true` for the audit trail.
- **Headless runs load the checkout's project settings**: a `.claude/settings.json`
  SessionStart hook in the checkout ran (`/tmp/hook-ran` existed), the SDK options print
  `settingSources: ["user", "project", "local"]`, and the action writes
  `~/.claude/settings.json` with `enableAllProjectMcpServers: true`, so a planted
  `.mcp.json` would be loaded too. `begin.sh`'s restore of `.claude/`, `CLAUDE.md`,
  `.mcp.json` and `.claude-plugin/` from the branch's merge base with the default branch
  is load-bearing, not belt-and-braces; the project's committed
  `.claude/settings.local.json` is never loaded by a run.
- Each action step spends ≈ 10–15 s installing Claude Code before the model runs; with
  checkouts and validation that is the ≈ 2.5 billed minutes of run-job scaffolding in
  the budget envelope.
- `--model <id>` in `claude_args` is honoured under the OAuth subscription token
  (`modelUsage: ["claude-opus-5"]` for an opus step, `claude-haiku-4-5` for the haiku
  ones); `total_cost_usd`, `num_turns`, `duration_ms`, `modelUsage`,
  `permission_denials` and `terminal_reason`/`subtype` are all in the result record.

## `gh` inside a job

`gh` infers the repository from the working tree. In a job without a checkout (a
`fire` step before checkout, a `resolve` job with only the sparse swarm tree)
`gh workflow run` fails with `failed to run git: fatal: not a git repository`. Every
`gh workflow run`, `gh run list` and `gh run view` in the dispatcher passes
`-R "$REPO"`. Cost of the lesson: one billed minute for a seven-second run.
