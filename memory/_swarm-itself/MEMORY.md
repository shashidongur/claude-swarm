# The swarm itself

Facts about the environment the swarm runs in, as opposed to any project it works on.

- [routine-environment](routine-environment.md) — what a cloud routine actually provides; only `.claude/` is discovered, `gh` is absent, cross-repo push works
- [actions-dispatch-gotchas](actions-dispatch-gotchas.md) — bash -e aborts guards; only Actions see the event payload
- [the-comment-is-the-dispatch](the-comment-is-the-dispatch.md) — changing how roles comment changes how they are dispatched; a stall is silent and green
- [v2-design](v2-design.md) — pipeline v2 in one page: the seventeen decisions with rationales, the open risks and what the adversarial reviews changed
- [claude-code-action-facts](claude-code-action-facts.md) — App token per step and revoked after; `github_token:` = override, no OIDC; chain actor is `github-actions[bot]`; the exchange needs the stub on the default branch; project settings load headless
