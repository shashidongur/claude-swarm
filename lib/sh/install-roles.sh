#!/usr/bin/env bash
# install-roles.sh — the role files a run job needs, into the project checkout (spec
# §16.1.3). Only the roles pipeline.json names (plus `critic`) are installed, from the
# swarm tree's .claude/agents/; a missing file is a hard failure (the tree is broken).
# Skills are never copied: the brief carries the role verbatim, and a project's own
# `.claude/skills` are the owner's.
#
#   install-roles.sh [--src DIR] [--dest DIR] [--pipeline FILE]
#       src      default $SWARM_ROOT/.claude/agents
#       dest     default .claude/agents (of the current directory)
#       pipeline default $SWARM_ROOT/pipeline.json
#
# A destination file the project tracks in git is never overwritten (the project's own
# agent of that name wins; a warning names it). Installed files are added to
# .git/info/exclude when the destination is inside a git work tree, so a read-class
# role's `git status --porcelain` (V18) stays clean and the files can never be
# committed by a write-class role's `git add -A`. Idempotent.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

src="$SWARM_ROOT/.claude/agents"
dest=".claude/agents"
pipeline="$SWARM_ROOT/pipeline.json"
while [ $# -gt 0 ]; do
  case $1 in
    --src) src=$2; shift 2 ;;
    --dest) dest=$2; shift 2 ;;
    --pipeline) pipeline=$2; shift 2 ;;
    *) die "install-roles: unknown argument $1" ;;
  esac
done

[ -f "$pipeline" ] || die "install-roles: no pipeline file at $pipeline"
[ -d "$src" ] || die "install-roles: no role directory at $src"

mapfile -t roles < <(jq -r '[.stages[]?.roles[]?.name] + ["critic"] | unique | .[]' "$pipeline")
[ ${#roles[@]} -gt 0 ] || die "install-roles: pipeline.json names no roles"

missing=()
for r in "${roles[@]}"; do
  [ -f "$src/$r.md" ] || missing+=("$r")
done
if [ ${#missing[@]} -gt 0 ]; then
  die "install-roles: role file(s) missing from $src: ${missing[*]}"
fi

mkdir -p "$dest" || die "install-roles: cannot create $dest"

in_git=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then in_git=1; fi
excl=""
if [ $in_git -eq 1 ]; then
  gitdir=$(git rev-parse --git-dir 2>/dev/null)
  if [ -n "$gitdir" ]; then
    mkdir -p "$gitdir/info"
    excl="$gitdir/info/exclude"
    [ -f "$excl" ] || : > "$excl"
  fi
fi

installed=0
skipped=0
for r in "${roles[@]}"; do
  target="$dest/$r.md"
  if [ $in_git -eq 1 ] && git ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
    printf '::warning::install-roles: %s is tracked by the project — kept, not overwritten\n' "$target"
    skipped=$((skipped + 1))
    continue
  fi
  cp "$src/$r.md" "$target" || die "install-roles: cannot write $target"
  installed=$((installed + 1))
  if [ -n "$excl" ]; then
    rel=${target#./}
    grep -qxF -- "/$rel" "$excl" 2>/dev/null || printf '/%s\n' "$rel" >> "$excl"
  fi
done

out installed "$installed"
log "install-roles: $installed role file(s) installed into $dest ($skipped kept as the project's own)"
exit 0
