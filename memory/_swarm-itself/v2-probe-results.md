---
name: v2-probe-results
description: What the v2 probe measured on GitHub Actions on 2026-09-08 — chain actor, override token, model map, transcript after death, step-timeout outcome, Contents-API CAS, project settings applied headless; what is still deferred to switch-on
metadata:
  type: reference
---

Measured on `shashidongur/meipadam` by `.github/workflows/swarm-probe.yml` (runs
34256463194 → 34260951104, 2026-09-08 17:20–18:07Z, ≈ 12 billed minutes, ≈ $0.45). The
probe ran from a feature branch: a `workflow_dispatch` workflow that has never existed on
the default branch cannot be dispatched by name (404), so the push of the probe file itself
ran the `fire` job.

| # | Question | Answer |
|---|---|---|
| R1 | Actor of a `workflow_dispatch` fired by `gh workflow run` under `github.token` | `github.actor` = `triggering_actor` = **`github-actions[bot]`**; `claude-code-action` accepts it with `allowed_bots: "github-actions,claude"` ("is in allowed_bots list, skipping human actor check"). Fire-and-verify by `run-name` found the run within seconds. |
| R2 | Does `github_token: ${{ github.token }}` bound the role to the job permissions | **Yes.** "Using provided GITHUB_TOKEN for authentication", no OIDC exchange, `Revoke app token` skipped. In a `contents: read, issues: read` job: `GET issues` → 200, `POST …/comments` → **403**, `git push` → **403 "Write access to repository not granted"** (agent mode still rewrites `origin` with the token — the refusal comes from the permissions, not the URL). |
| R3 | Is `--model` honoured under the OAuth subscription token | **Yes.** `--model claude-opus-5` → `modelUsage: {"claude-opus-5"}` (5 turns, $0.197); `claude-haiku-4-5` and `claude-sonnet-5` likewise. |
| R4 | Is the Contents-API `PUT` with a stale `sha` a compare-and-swap | **Yes.** Create → sha A; update with different content and `sha: A` → sha B; update with the stale `A` → `HTTP 409 {"message":"issues/probe.json does not match A"}`, `gh` exit 1. Blob shas are content-addressed: identical content re-written with the current sha succeeds and changes nothing. The orphan `swarm/state` branch was created with the Git Data API (tree → parentless commit → ref). |
| R5a | Does the execution file exist after a `--max-turns` overrun | **Yes** (39 KB). Step `outcome=failure` ("Reached maximum number of turns"), `execution_file` output set, result record `{subtype:"error_max_turns", is_error:true, num_turns:2}`. |
| R5b | Does it exist after a step timeout kills the action mid-command | **Not exercisable**: Claude Code backgrounds long `sleep` commands, so the model returned in seconds every time. The file is written only when the SDK query returns; assume **absent** after a hard kill and tolerate it (`exec-stats.sh` → `{present:false}`). |
| R6 | What does a step killed by `timeout-minutes` report; do `if: always()` steps run | `outcome=failure`, `conclusion=success` (with `continue-on-error`) — **not `cancelled`**; later `if: always()` steps ran. Classify `timeout` = failure ∧ no result record ∧ step duration ≥ timeout − 15 s (from `gh run view --json jobs`). |
| R30 | Are project `.claude/settings.json` hooks applied in headless runs | **Yes.** A SessionStart hook planted in the checkout ran; SDK options show `settingSources: ["user","project","local"]`, and the action writes `/home/runner/.claude/settings.json` with `enableAllProjectMcpServers: true` (a planted `.mcp.json` would load too). `begin.sh`'s restore of `.claude/`, `CLAUDE.md`, `.mcp.json`, `.claude-plugin/` from the merge base is load-bearing. |
| R28/R29 | App-token reach; can it push workflow files or merge a PR | **Deferred to switch-on.** The OIDC → App-token exchange refused to run: "Workflow validation failed. The workflow file must exist and have identical content to the version on the repository's default branch." Every write-class job therefore needs the caller's stub on the default branch; the read class (override token) runs from any branch. Until measured, G35 (merge by an approver) and G29(d) (activity by `claude[bot]` outside the branch) assume the worst. |

Other facts picked up on the way:

- `gh workflow run` / `gh run list` in a job without a checkout fail with
  `failed to run git: fatal: not a git repository` — pass `-R "$REPO"` everywhere.
- Each `claude-code-action` step spends ≈ 10–15 s installing Claude Code before the model
  runs; a job with role + retry + critic pays it three times.
- The execution file is written with `show_full_output: false` too ("Log saved to …").
- Commits made through the Contents API under `github.token` carry author
  `github-actions[bot]` and `verification.verified: true` — automatic for any API writer,
  so not a trust anchor (the HMAC in §4.1 stays).
