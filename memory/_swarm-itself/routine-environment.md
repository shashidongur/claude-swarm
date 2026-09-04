---
name: routine-environment
description: What a Claude Code cloud routine actually provides — measured by spikes 1-4, not inferred from docs
metadata:
  type: reference
---

Measured on 2026-09-04 by the `swarm-spike-probe` routine against
`shashidongur/claude-swarm` + `shashidongur/meipadam`. Recorded because three of these
contradict what the documentation implies, and one contradicts what this repo was
originally built to assume.

## Workspace

Both repositories are cloned **side by side**, each from its default branch, under the
session's home directory:

    /home/user/claude-swarm
    /home/user/meipadam

`cwd` is the parent (`/home/user`), not either repo. Do not assume you start inside one.

## Cross-repo push works

A routine can commit and push to the **second** repository while working on the first —
`claude/spike-probe-<ts>` pushed to `claude-swarm` cleanly, with `meipadam`'s tree
untouched. This is what makes memory pool in one place instead of scattering across
every target, and it was the spike that could have forced a redesign.

## Only `.claude/` is discovered

Identical probes were placed in both layouts. The result was unambiguous:

| Location | Result |
|---|---|
| `skills/spike-probe/SKILL.md` | `Unknown skill: spike-probe` |
| `.claude/skills/spike-probe-dot/SKILL.md` | loaded |
| `agents/spike-probe.md` | `Agent type 'spike-probe' not found` |
| `.claude/agents/spike-probe-dot.md` | resolved and ran |

Both files were confirmed present on disk in every case. The root-level layout is the
**plugin** layout, read only when a plugin is installed — which a routine does not do.

**The trap:** a role in the wrong directory does not error. It is simply absent, and the
orchestrator silently has fewer roles than it thinks.

## Agents ARE discovered cross-repo — tool restrictions are enforced

This is the finding that improved the design. The swarm was built assuming roles would
have to be pasted in as text, which would have made every `tools:` list advisory and left
the routine's own allowlist as the only real perimeter. Not so: `.claude/agents/` in the
cloned swarm repo resolves by name, so `tools:`, `disallowedTools:` and `permissionMode`
are enforced by the harness.

Two perimeters, both real: the routine's allowlist is the outer bound, the role's own
list the inner one.

## `gh` is not on PATH

The probe reported *"no `gh` CLI available to me"* and used the GitHub MCP tools instead
— `mcp__github__issue_read`, `mcp__github__add_issue_comment`, `mcp__github__issue_write`.
Every `gh` invocation written in this repo is shorthand for the equivalent MCP call. A
routine must reach for the tool, not the binary.

## MCP connectors are attached by default

Creating the routine silently attached every connected connector, including Gmail, which
a code routine has no business holding. Prune `mcp_connections` on any routine that does
not need them.
