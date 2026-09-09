#!/usr/bin/env bash
# pack-tree.sh — the swarm tree artifact `resolve` uploads for the run jobs (spec §13.3,
# §16.1.1). Run jobs never check out claude-swarm (no token of the swarm repo enters a
# job with a model step); they download this tree as `.swarm` instead.
#
#   pack-tree.sh [--out DIR] [--state FILE] [--config FILE] [--issue N]
#                [--stage S] [--role R[:lane]] [--lane L] [--attempt N]
#       Copies .claude/agents, lib (minus lib/conformance — its fixtures carry fake
#       tokens and are of no use to a role), pipeline.json, templates and memory of
#       $SWARM_ROOT into DIR (default swarm-tree/), never .git, and writes
#       DIR/.swarm-run/state.json (the snapshot resolve verified), config.json and
#       pipeline.json (this role's slice, below). Values default from the environment
#       (STATE_JSON, CONFIG_JSON, ISSUE, STAGE, ROLE, LANE, ATTEMPT) and, for the
#       stage/role/attempt, from the snapshot's `current`. Without a state file and
#       with lib/sh/state.sh present, the snapshot is `state.sh read <issue>`.
#   pack-tree.sh slice <pipeline.json> <stage> <role[:lane]> [attempt]
#       Prints the role's pipeline.json slice: the stage entry without its roles, the
#       role entry with `<lane>`/`<attempt>` substituted in its artifact names, the
#       class configuration and every top-level list a run job reads.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

slice() { # <pipeline.json> <stage> <role[:lane]> [attempt]
  local pipeline=$1 stage=$2 role=$3 attempt=${4:-1} base lane
  [ -f "$pipeline" ] || die "pack-tree: no pipeline file at $pipeline"
  base=${role%%:*}
  lane=""
  [ "$role" != "$base" ] && lane=${role#*:}
  jq --arg stage "$stage" --arg role "$base" --arg lane "$lane" --arg attempt "$attempt" '
    def subst: gsub("<lane>"; $lane) | gsub("<attempt>"; $attempt);
    (.stages // [] | map(select(.name == $stage)) | first) as $s
    | if $s == null then error("pack-tree: unknown stage \($stage)") else . end
    | ($s.roles // [] | map(select(.name == $role)) | first) as $r
    | if $r == null then error("pack-tree: unknown role \($role) in stage \($stage)") else . end
    | ($r.class // "read") as $class
    | {
        v: 2,
        stage: ($s | del(.roles)),
        role: ($r | .artifacts = ((.artifacts // []) | map(subst))),
        lane: (if $lane == "" then null else $lane end),
        attempt: ($attempt | tonumber),
        class: $class,
        class_config: (.classes[$class] // {}),
        critic_config: (.classes.critic // {}),
        artifacts: (($r.artifacts // []) | map(subst)),
        reads: ($r.reads // []),
        memory: ($r.memory // []),
        restore_from_base: (.restore_from_base // []),
        protected_paths: (.protected_paths // []),
        deny_paths: (.deny_paths // []),
        bash_deny: (.bash_deny // []),
        models: (.models // {}),
        limits: (.limits // {}),
        critic_defaults: (.critic_defaults // {}),
        memory_fenced: (.memory_fenced // []),
        paths: (.paths // {}),
        emoji: (.emoji // {})
      }' "$pipeline"
}

if [ "${1:-}" = "slice" ]; then
  shift
  [ $# -ge 3 ] || die "usage: pack-tree.sh slice <pipeline.json> <stage> <role[:lane]> [attempt]"
  slice "$@"
  exit $?
fi

outdir="swarm-tree"
state_file=${STATE_JSON:-}
config_file=${CONFIG_JSON:-}
issue=${ISSUE:-}
stage=${STAGE:-}
role=${ROLE:-}
lane=${LANE:-}
attempt=${ATTEMPT:-}
while [ $# -gt 0 ]; do
  case $1 in
    --out) outdir=$2; shift 2 ;;
    --state) state_file=$2; shift 2 ;;
    --config) config_file=$2; shift 2 ;;
    --issue) issue=$2; shift 2 ;;
    --stage) stage=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --lane) lane=$2; shift 2 ;;
    --attempt) attempt=$2; shift 2 ;;
    *) die "pack-tree: unknown argument $1" ;;
  esac
done

snapshot=$(tmpf .state) || die "pack-tree: cannot create a temporary file"
if [ -n "$state_file" ]; then
  [ -f "$state_file" ] || die "pack-tree: state file not found: $state_file"
  cp "$state_file" "$snapshot"
elif [ -n "$issue" ] && [ -x "$SWARM_LIB/state.sh" ]; then
  "$SWARM_LIB/state.sh" read "$issue" > "$snapshot" 3>/dev/null \
    || die "pack-tree: state.sh read $issue failed (exit $?)"
else
  die "pack-tree: no state snapshot (set STATE_JSON, or ISSUE with lib/sh/state.sh present)"
fi
jq -e 'type == "object" and .v == 2' "$snapshot" >/dev/null 2>&1 || die "pack-tree: the state snapshot is not a v2 state document"

[ -n "$config_file" ] || die "pack-tree: CONFIG_JSON (or --config) is required"
[ -f "$config_file" ] || die "pack-tree: config file not found: $config_file"

[ -n "$stage" ] || stage=$(jq -r '.stage // empty' "$snapshot")
[ -n "$role" ] || role=$(jq -r '.current.role // empty' "$snapshot")
[ -n "$attempt" ] || attempt=$(jq -r '.current.attempt // 1' "$snapshot")
if [ -n "$lane" ] && [ "${role%%:*}" = "$role" ]; then role="$role:$lane"; fi
[ -n "$stage" ] && [ -n "$role" ] || die "pack-tree: stage and role are unknown (not in the environment, nor in the snapshot's current)"

sliced=$(tmpf .slice) || die "pack-tree: cannot create a temporary file"
slice "$SWARM_ROOT/pipeline.json" "$stage" "$role" "$attempt" > "$sliced" || die "pack-tree: cannot build the pipeline slice for $stage/$role"

rm -rf "$outdir"
mkdir -p "$outdir/.swarm-run" || die "pack-tree: cannot create $outdir"
copied=0
for p in .claude/agents lib pipeline.json templates memory; do
  src="$SWARM_ROOT/$p"
  [ -e "$src" ] || { log "pack-tree: $p absent in $SWARM_ROOT — skipped"; continue; }
  mkdir -p "$outdir/$(dirname "$p")"
  cp -R "$src" "$outdir/$p" || die "pack-tree: cannot copy $p"
  copied=$((copied + 1))
done
[ $copied -gt 0 ] || die "pack-tree: nothing to pack under $SWARM_ROOT"
rm -rf "$outdir/lib/conformance"
find "$outdir" -name .git -prune -exec rm -rf {} + 2>/dev/null

cp "$snapshot" "$outdir/.swarm-run/state.json" || die "pack-tree: cannot write the state snapshot"
jq . "$config_file" > "$outdir/.swarm-run/config.json" || die "pack-tree: config file is not JSON: $config_file"
cp "$sliced" "$outdir/.swarm-run/pipeline.json" || die "pack-tree: cannot write the pipeline slice"
rm -f "$snapshot" "$sliced"

out tree "$outdir"
log "pack-tree: $outdir ready for $stage/$role attempt $attempt ($(du -sh "$outdir" 2>/dev/null | cut -f1))"
exit 0
