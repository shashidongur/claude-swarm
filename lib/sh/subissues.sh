#!/usr/bin/env bash
# subissues.sh — the tracking sub-issues of a swarm issue (spec §9.2, D6).
#
#   subissues.sh create <issue> <result.json>
#       One sub-issue per `subissues[]` entry of the planner's result, idempotent on
#       the title prefix `[#<issue>/<lane>]` (an open or closed issue carrying it is
#       reused, never duplicated). Created with
#         gh issue create --title "[#N/<lane>] <title>" --body-file <rendered body>
#            --label swarm:lane --label swarm:hands-off --parent N --type Task
#       and, when that call errors (no issue types, or no sub-issue support on the
#       repository), again without --parent/--type — `flat` becomes true. The body
#       (lib/templates/sub-issue.tmpl) fences nothing: the planner's text is sanitised
#       and lands on an issue nothing ever dispatches on (both labels, G4).
#       Prints {"<lane>": <number>, …, "flat": bool} — the `subissues` routing fact.
#       Exit 0; a lane whose issue could not be created is left out (logged).
#
#   subissues.sh close <issue> <reason>
#       Closes every sub-issue recorded in state.subissues (`gh issue close <n>
#       --comment <reason>`), silently under github.token. Exit 0.
#
# Environment: REPO, SWARM_STATE_KEY (close reads state), GH_TOKEN; BRANCH
# (state.branch when unset); RUN_DIR (default .swarm-run — body files resolve
# under its artifacts/).
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

RUN_DIR=${RUN_DIR:-.swarm-run}

# existing_number <issue> <lane> → the number of an issue titled "[#N/<lane>] …", or nothing
existing_number() {
  local issue=$1 lane=$2 prefix
  prefix="[#$issue/$lane]"
  gh issue list -R "$REPO" --state all --label swarm:lane --search "\"$prefix\" in:title" --json number,title --limit 50 2>/dev/null \
    | jq -r --arg p "$prefix" '[.[]? | select(.title | startswith($p))] | first | .number // empty' 2>/dev/null
}

# number_of <gh issue create output> → the issue number (a URL, a JSON object, or a bare number)
number_of() {
  local s=$1 n
  n=$(printf '%s' "$s" | jq -r '.number // empty' 2>/dev/null)
  [ -n "$n" ] || n=$(printf '%s' "$s" | grep -oE '/issues/[0-9]+' | tail -1 | grep -oE '[0-9]+$')
  [ -n "$n" ] || n=$(printf '%s' "$s" | grep -oE '^[0-9]+$' | head -1)
  printf '%s' "$n"
}

cmd_create() {
  local issue=${1:-} result=${2:-} n i lane title bf src body out num flat=false rc title_s parent="" rabs abs
  [ -n "$issue" ] && [ -n "$result" ] || die "usage: subissues.sh create <issue> <result.json>"
  require_env REPO
  [ -f "$result" ] || die "subissues: no such file: $result"
  local map="{}" branch=${BRANCH:-}
  n=$(jq '(.subissues // []) | length' "$result")
  i=0
  while [ "$i" -lt "$n" ]; do
    lane=$(jq -r ".subissues[$i].lane // empty" "$result")
    title=$(jq -r ".subissues[$i].title // empty" "$result")
    bf=$(jq -r ".subissues[$i].body_file // empty" "$result")
    i=$((i + 1))
    [ -n "$lane" ] && [ -n "$title" ] || { log "subissues: entry $((i - 1)) lacks lane or title — skipped"; continue; }
    case $lane in *[!A-Za-z0-9_-]*) log "subissues: lane '$lane' refused"; continue ;; esac
    if num=$(existing_number "$issue" "$lane") && [ -n "$num" ]; then
      log "subissues: [#$issue/$lane] exists as #$num"
      map=$(printf '%s' "$map" | jq -c --arg l "$lane" --argjson n "$num" '.[$l] = $n')
      continue
    fi
    bf=${bf#.swarm-run/}
    bf=${bf#artifacts/}
    src=""
    # The path comes from the role's result.json. Stripping two prefixes is not a
    # containment check: resolve it and require that it really lands under
    # artifacts/, the same rule memory-pr.sh applies to its content_file. The body
    # goes out through `gh issue create --body-file`, which does not pass through
    # _prepare_body, so a file from outside would be published verbatim.
    if [ -n "$bf" ] && [ -f "$RUN_DIR/artifacts/$bf" ] && [ ! -L "$RUN_DIR/artifacts/$bf" ]; then
      rabs=$(realpath -e -- "$RUN_DIR/artifacts" 2>/dev/null) || rabs=""
      abs=$(realpath -e -- "$RUN_DIR/artifacts/$bf" 2>/dev/null) || abs=""
      if [ -n "$rabs" ] && [ -n "$abs" ]; then
        case $abs in "$rabs"/*) src="$RUN_DIR/artifacts/$bf" ;; *) log "subissues: body_file '$bf' resolves outside $RUN_DIR/artifacts — ignored" ;; esac
      fi
    fi
    body=$(tmpf .md) || die "subissues: no temp dir"
    if [ -n "$src" ]; then
      "$SWARM_LIB/render.sh" sub-issue "$body" --arg issue "$issue" --arg lane "$lane" --arg branch "${branch:-(not created yet)}" \
        --srawfile body "$src" || { rm -f "$body"; log "subissues: cannot render the body for $lane"; continue; }
    else
      "$SWARM_LIB/render.sh" sub-issue "$body" --arg issue "$issue" --arg lane "$lane" --arg branch "${branch:-(not created yet)}" \
        --sarg body "(the planner attached no body for this lane)" || { rm -f "$body"; log "subissues: cannot render the body for $lane"; continue; }
    fi
    title_s=$(printf '%s' "$title" | sanitize | tr -d '\r\n' | cut -c1-80)
    out=$(gh issue create -R "$REPO" --title "[#$issue/$lane] $title_s" --body-file "$body" \
          --label swarm:lane --label swarm:hands-off --parent "$issue" --type Task 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
      log "subissues: --parent/--type refused for $lane ($(printf '%s' "$out" | tail -n 1 | head -c 160)) — creating it flat"
      out=$(gh issue create -R "$REPO" --title "[#$issue/$lane] $title_s" --body-file "$body" \
            --label swarm:lane --label swarm:hands-off 2>&1)
      rc=$?
      flat=true
    fi
    rm -f "$body"
    if [ $rc -ne 0 ]; then
      log "subissues: could not create [#$issue/$lane]: $(printf '%s' "$out" | tail -n 1 | head -c 200)"
      continue
    fi
    num=$(number_of "$out")
    if [ -z "$num" ]; then
      log "subissues: created [#$issue/$lane] but could not read its number from: $(printf '%s' "$out" | head -c 200)"
      continue
    fi
    map=$(printf '%s' "$map" | jq -c --arg l "$lane" --argjson n "$num" '.[$l] = $n')
    log "subissues: created [#$issue/$lane] as #$num${parent:+ (child of #$parent)}"
  done
  printf '%s' "$map" | jq -c --argjson f "$flat" '. + {flat: $f}'
  exit 0
}

cmd_close() {
  local issue=${1:-} reason=${2:-Done} snap nums n
  [ -n "$issue" ] || die "usage: subissues.sh close <issue> <reason>"
  require_env REPO SWARM_STATE_KEY
  snap=$(tmpf .json) || die "subissues: no temp dir"
  "$SWARM_LIB/state.sh" read "$issue" > "$snap" 2>/dev/null || { rm -f "$snap"; log "subissues: no readable state for #$issue — nothing closed"; exit 0; }
  nums=$(jq -r '(.subissues // {}) | to_entries[] | select(.key != "flat") | select(.value | type == "number") | .value' "$snap")
  rm -f "$snap"
  n=0
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    if gh issue close -R "$REPO" "$num" --comment "$(printf '%s' "$reason" | sanitize | head -c 400)" >/dev/null 2>&1; then
      n=$((n + 1))
    else
      log "subissues: could not close #$num (already closed, or refused)"
    fi
  done <<< "$nums"
  log "subissues: closed $n sub-issue(s) of #$issue"
  exit 0
}

case ${1:-} in
  create) shift; cmd_create "$@" ;;
  close) shift; cmd_close "$@" ;;
  *) sed -n '2,25p' "$0" >&2; exit 1 ;;
esac
