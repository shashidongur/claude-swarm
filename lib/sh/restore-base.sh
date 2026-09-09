#!/usr/bin/env bash
# restore-base.sh — put the files that steer Claude Code back to what they are at the
# merge base with the default branch, so nothing a role committed to its own branch
# can steer the next model that reads that branch.
#
#   restore-base.sh [--label <word>] [--pipeline <json>] [--default-branch <name>]
#
# The paths come from `.restore_from_base` of the pipeline document — by default the
# role's slice at $RUN_DIR/pipeline.json, else the swarm tree's pipeline.json. A path
# that exists at the merge base is checked out from it; a path absent there but
# present in the working tree is deleted.
#
# Why it is load-bearing (probe R30, 2026-09-08): a project .claude/settings.json
# SessionStart hook DOES run under claude-code-action, the action writes
# enableAllProjectMcpServers: true into the user settings, and the SDK reports
# settingSources ["user", "project", "local"] — so a planted .claude/, CLAUDE.md,
# .mcp.json or .claude-plugin/ in the checkout executes. Two callers need it:
# begin.sh, before a role runs, and the critic job, which checks out the very head
# the write role just pushed in order to judge it.
#
# --label names the caller in the log lines ("begin", "critic"). Exits non-zero only
# when a path exists at the merge base and cannot be restored — that is a tree the
# caller must not run a model on.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

LABEL=begin
PIPELINE=""
DEFAULT_BRANCH=${DEFAULT_BRANCH:-}
while [ $# -gt 0 ]; do
  case $1 in
    --label) LABEL=${2:-begin}; shift 2 ;;
    --pipeline) PIPELINE=${2:-}; shift 2 ;;
    --default-branch) DEFAULT_BRANCH=${2:-}; shift 2 ;;
    *) log "restore-base: unknown option $1 (ignored)"; shift ;;
  esac
done

if [ -z "$PIPELINE" ]; then
  PIPELINE="${RUN_DIR:-.swarm-run}/pipeline.json"
  [ -f "$PIPELINE" ] || PIPELINE="$SWARM_ROOT/pipeline.json"
fi
[ -f "$PIPELINE" ] || { log "$LABEL: no pipeline document at $PIPELINE — nothing restored"; exit 0; }
if [ -z "$DEFAULT_BRANCH" ]; then
  # The config document travels in the handoff, so the critic job need not be told.
  for c in "${CONFIG_JSON:-}" "${RUN_DIR:-.swarm-run}/config.json"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    DEFAULT_BRANCH=$(jq -r '.default_branch // empty' "$c" 2>/dev/null) || DEFAULT_BRANCH=""
    [ -n "$DEFAULT_BRANCH" ] && break
  done
fi
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "$LABEL: not a git tree — nothing restored"; exit 0; }

restored=()
deleted=()
git fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null || true
base_ref=""
for cand in "origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"; do
  if git rev-parse -q --verify "$cand^{commit}" >/dev/null 2>&1; then base_ref=$cand; break; fi
done
mb=""
[ -n "$base_ref" ] && mb=$(git merge-base "$base_ref" HEAD 2>/dev/null)
[ -n "$mb" ] || mb=$(git rev-parse HEAD 2>/dev/null)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if git cat-file -e "$mb:$p" 2>/dev/null; then
    rm -rf -- "./$p"
    git checkout -q "$mb" -- "$p" 2>/dev/null || die "$LABEL: cannot restore $p from the merge base $mb"
    restored+=("$p")
  elif [ -e "./$p" ] || [ -L "./$p" ]; then
    rm -rf -- "./$p"
    deleted+=("$p")
  fi
done < <(jq -r '.restore_from_base[]?' "$PIPELINE")
[ ${#restored[@]} -eq 0 ] || log "$LABEL: restored from merge base ${mb:0:12}: ${restored[*]}"
[ ${#deleted[@]} -eq 0 ] || printf '::warning::%s: deleted from the working tree (absent at the merge base %s, present on the branch): %s\n' "$LABEL" "${mb:0:12}" "${deleted[*]}"
exit 0
