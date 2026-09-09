#!/usr/bin/env bash
# perimeter.sh — the G29(b) and G29(d) helpers advance.sh calls (spec §5.3, §16.1.3).
#
#   perimeter.sh manifests <base> <head>
#       For every `config.gate_manifests` file (package.json-like) that exists at
#       <head> or <base>: the `scripts.<name>` entries named in `config.gate_scripts`,
#       the top-level blocks named in `config.gate_blocks` (the test runner's own
#       configuration block, when it lives in the manifest) and `coverageThreshold`
#       wherever it sits are compared between the two revisions with jq. One line per
#       changed file on stdout — `<file>: <key>, <key>`
#       (a file absent on one side names `file`) — nothing when the gates are intact.
#       Exit 0 always; the caller decides (a non-empty answer is blocked:perimeter).
#
#   perimeter.sh activity <since> <branch>
#       Repository activity since <since> (ISO-8601) by the write role's identity
#       (`claude[bot]`, or $SWARM_WRITE_ACTOR) on any ref but refs/heads/<branch>, or a
#       force_push / branch_deletion on the branch itself — from
#       `GET repos/{o}/{r}/activity?time_period=day`. One line per offending entry:
#       `<activity_type> <ref> <before>..<after> by <actor> at <timestamp>`.
#       When the endpoint fails: `git ls-remote origin` is compared with the snapshot
#       taken at claim time ($REFS_SNAPSHOT, default .swarm-run/refs-snapshot.txt),
#       ignoring refs/heads/<branch>, the state branch and refs/pull/*; a changed or
#       new ref is reported as `ref-changed <ref> <before>..<after> by unknown
#       (activity endpoint unavailable)`. No snapshot → one `::warning::`, nothing
#       reported. Exit 0 always.
#
# Environment: REPO, CONFIG_JSON (gate_manifests, gate_scripts, gate_blocks, state_branch),
# GH_TOKEN; SWARM_WRITE_ACTOR (default claude[bot]); REFS_SNAPSHOT.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

cfg() { # <jq expr> → raw value(s) or nothing
  [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ] || return 0
  jq -r "$1 // empty" "$CONFIG_JSON" 2>/dev/null
}

# gate_view <rev> <file> → the gate-relevant slice of a manifest at a revision
# (`{}` when the file is absent there; `{"unparsable": true}` when not JSON)
gate_view() {
  local rev=$1 file=$2 raw scripts blocks
  raw=$(git show "$rev:$file" 2>/dev/null) || { printf '{"absent":true}'; return 0; }
  scripts=$(cfg '.gate_scripts' | jq -c '.' 2>/dev/null)
  [ -n "$scripts" ] && [ "$scripts" != "null" ] || scripts='["test:ci","test","lint","typecheck","type-check"]'
  blocks=$(cfg '.gate_blocks' | jq -c '.' 2>/dev/null)
  [ -n "$blocks" ] && [ "$blocks" != "null" ] || blocks='[]'
  printf '%s' "$raw" | jq -c --argjson gs "$scripts" --argjson gb "$blocks" '
    { scripts: ((.scripts // {}) | with_entries(select(.key as $k | $gs | index($k) != null))),
      blocks: (with_entries(select(.key as $k | $gb | index($k) != null))),
      coverageThreshold: ([.. | objects | .coverageThreshold? // empty] | first // null) }' 2>/dev/null \
    || printf '{"unparsable":true}'
}

cmd_manifests() {
  local base=${1:-} head=${2:-} f a b keys
  [ -n "$base" ] && [ -n "$head" ] || die "usage: perimeter.sh manifests <base> <head>"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "perimeter: not a git work tree"; exit 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    a=$(gate_view "$base" "$f")
    b=$(gate_view "$head" "$f")
    [ "$a" = "$b" ] && continue
    if printf '%s' "$a" | jq -e '.absent == true' >/dev/null 2>&1 || printf '%s' "$b" | jq -e '.absent == true' >/dev/null 2>&1; then
      printf '%s: file\n' "$f"
      continue
    fi
    keys=$(jq -rn --argjson a "$a" --argjson b "$b" '
      [ (($a.scripts // {}) + ($b.scripts // {}) | keys[]) as $k | select(($a.scripts // {})[$k] != ($b.scripts // {})[$k]) | "scripts.\($k)" ]
      + [ (($a.blocks // {}) + ($b.blocks // {}) | keys[]) as $k | select(($a.blocks // {})[$k] != ($b.blocks // {})[$k]) | $k ]
      + (if $a.coverageThreshold != $b.coverageThreshold then ["coverageThreshold"] else [] end)
      + (if ($a.unparsable // false) != ($b.unparsable // false) then ["unparsable"] else [] end)
      | unique | join(", ")')
    printf '%s: %s\n' "$f" "$keys"
  done < <(cfg '.gate_manifests[]')
  exit 0
}

cmd_activity() {
  local since=${1:-} branch=${2:-} actor raw rc snap state_branch
  [ -n "$since" ] && [ -n "$branch" ] || die "usage: perimeter.sh activity <since> <branch>"
  require_env REPO
  actor=${SWARM_WRITE_ACTOR:-claude[bot]}
  raw=$(gh_json --paginate "repos/$REPO/activity?time_period=day&per_page=100" 2>/dev/null)
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -r --arg since "$since" --arg actor "$actor" --arg ref "refs/heads/$branch" '
      .[] | select(type == "object")
      | select((.timestamp // "") >= $since)
      | select((.actor.login // "") == $actor)
      | select((.ref // "") != $ref or ((.activity_type // "") | IN("force_push", "branch_deletion")))
      | "\(.activity_type // "?") \(.ref // "?") \((.before // "") | .[0:12])..\((.after // "") | .[0:12]) by \(.actor.login) at \(.timestamp // "?")"'
    exit 0
  fi
  log "perimeter: the activity endpoint is unavailable (gh exit $rc) — comparing git ls-remote with the claim-time snapshot"
  snap=${REFS_SNAPSHOT:-.swarm-run/refs-snapshot.txt}
  if [ ! -f "$snap" ]; then
    printf '::warning::perimeter: no ref snapshot at %s; the activity check for #%s could not run\n' "$snap" "${ISSUE:-?}" >&2
    exit 0
  fi
  state_branch=$(cfg '.state_branch')
  state_branch=${state_branch:-swarm/state}
  git ls-remote origin 2>/dev/null | awk '{ print $2 "\t" $1 }' | LC_ALL=C sort > "$snap.now"
  awk '{ print $2 "\t" $1 }' "$snap" 2>/dev/null | LC_ALL=C sort > "$snap.then"
  # a line in "now" whose ref is missing from "then" or carries another sha
  join -t "$(printf '\t')" -a 1 -e '(none)' -o '0,2.2,1.2' "$snap.now" "$snap.then" \
    | awk -F'\t' -v skip="refs/heads/$branch" -v state="refs/heads/$state_branch" '
        $1 == skip || $1 == state || $1 ~ /^refs\/pull\// { next }
        $2 != $3 { printf "ref-changed %s %s..%s by unknown (activity endpoint unavailable)\n", $1, substr($2, 1, 12), substr($3, 1, 12) }'
  rm -f "$snap.now" "$snap.then"
  exit 0
}

case ${1:-} in
  manifests) shift; cmd_manifests "$@" ;;
  activity) shift; cmd_activity "$@" ;;
  *) sed -n '2,25p' "$0" >&2; exit 1 ;;
esac
