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
#   perimeter.sh snapshot <file>
#       The claim-time ref snapshot the fallback below compares against: one
#       `<sha><TAB><ref>` line per ref, from `GET repos/{o}/{r}/git/refs` (any
#       failure falls back to `git ls-remote origin`). resolve.sh writes it into the
#       packed swarm tree, so it travels in the swarm-tree artifact — a role can
#       neither reach it nor replace it, and it exists for every claimed dispatch.
#       Exit 0 always; an empty answer means the snapshot could not be taken and the
#       file is not written, which `activity` then reports rather than hides.
#
#   perimeter.sh activity <since> <branch>
#       Repository activity since <since> (ISO-8601) by any identity the swarm can
#       act under — `claude[bot]` (the write role's App token), `github-actions[bot]`
#       (github.token, which the dispatcher's own steps use) and $SWARM_WRITE_ACTOR —
#       on any ref but refs/heads/<branch>, or a force_push / branch_deletion on the
#       branch itself. From `GET repos/{o}/{r}/activity?time_period=day`. One line per
#       offending entry: `<activity_type> <ref> <before>..<after> by <actor> at
#       <timestamp>`. Human activity is deliberately not reported: a person pushing
#       their own work during a run is not a perimeter breach.
#       When the endpoint fails: `git ls-remote origin` is compared with the claim-time
#       snapshot ($REFS_SNAPSHOT, default .swarm-claim/refs-snapshot.txt — never under
#       $RUN_DIR, which arrives from the role's own handoff artifact), ignoring
#       refs/heads/<branch> and refs/pull/*. A changed, new or deleted ref is reported
#       as `ref-changed`/`ref-created`/`ref-deleted <ref> <before>..<after> by unknown
#       (activity endpoint unavailable)`. The state branch is NOT excluded: a rollback
#       of the signed state lands exactly there. No snapshot → the missing check is
#       reported as a line, not swallowed as a warning. Exit 0 always.
#
# Environment: REPO, CONFIG_JSON (gate_manifests, gate_scripts, gate_blocks, state_branch),
# GH_TOKEN; SWARM_WRITE_ACTOR (adds an identity); REFS_SNAPSHOT.
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
  # npm runs pre<name> and post<name> around every script, and the install lifecycle
  # around `npm ci`, so a gate script left untouched still runs attacker code if one
  # of those is added. They are part of the gate whether the project lists them or not.
  scripts=$(printf '%s' "$scripts" | jq -c '. + (map("pre" + ., "post" + .)) + ["preinstall","install","postinstall","prepare","prepublish"] | unique')
  # A test runner configured inside the manifest decides which tests run and which
  # files count for coverage, so changing that block moves the gate without touching a
  # script. Which block that is depends on the project's stack, so the project names it
  # in `gate_blocks`; config.sh warns when gate_manifests is set and this is not.
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

# refs_now <out>: `<sha><TAB><ref>` for every ref, API first, git second. Empty
# output (and a non-zero exit) when neither source answers.
refs_now() {
  local out=$1 raw
  if [ -n "${REPO:-}" ]; then
    raw=$(gh_json --paginate "repos/$REPO/git/refs?per_page=100" 2>/dev/null) \
      && printf '%s' "$raw" | jq -r 'if type == "array" then .[] else . end | select(type == "object") | select(.object.sha != null) | "\(.object.sha)\t\(.ref)"' 2>/dev/null > "$out" \
      && [ -s "$out" ] && return 0
  fi
  git ls-remote origin 2>/dev/null > "$out" && [ -s "$out" ] && return 0
  : > "$out"
  return 1
}

cmd_snapshot() {
  local out=${1:-} tmp
  [ -n "$out" ] || die "usage: perimeter.sh snapshot <file>"
  tmp="$out.partial"
  if refs_now "$tmp"; then
    LC_ALL=C sort < "$tmp" > "$out"
    rm -f "$tmp"
    log "perimeter: ref snapshot written to $out ($(wc -l < "$out" | tr -d ' ') refs)"
  else
    rm -f "$tmp"
    printf '::warning::perimeter: could not take a ref snapshot for #%s; the G29(d) fallback will report itself as not run\n' "${ISSUE:-?}" >&2
  fi
  exit 0
}

cmd_activity() {
  local since=${1:-} branch=${2:-} role_actors raw rc snap now then_ state_branch
  [ -n "$since" ] && [ -n "$branch" ] || die "usage: perimeter.sh activity <since> <branch>"
  require_env REPO
  state_branch=$(cfg '.state_branch'); state_branch=${state_branch:-swarm/state}
  # Two identities, two rules.
  #   claude[bot] (the write role's App token, plus $SWARM_WRITE_ACTOR) has business on
  #   exactly one ref: the integration branch. Anything else it touches is reported —
  #   the state branch included, which it should never write at all.
  #   github-actions[bot] is github.token, which the dispatcher's own steps use: it
  #   writes the signed state on every transition and lands the artifacts commit on the
  #   integration branch, so those two refs are its normal work and are not reported.
  #   Any OTHER ref it touches is, which is the path that reaches `main` without ever
  #   raising a pull_request event.
  # A force-push or a branch deletion is reported for either identity on any ref.
  # A human pushing their own work during a run is never reported.
  role_actors=$(jq -cn --arg extra "${SWARM_WRITE_ACTOR:-}" \
    '["claude[bot]"] + (if $extra == "" then [] else [$extra] end) | unique')
  raw=$(gh_json --paginate "repos/$REPO/activity?time_period=day&per_page=100" 2>/dev/null)
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -r --arg since "$since" --argjson role_actors "$role_actors" \
      --arg ref "refs/heads/$branch" --arg state_ref "refs/heads/$state_branch" '
      .[] | select(type == "object")
      | select((.timestamp // "") >= $since)
      | (.actor.login // "") as $a | (.ref // "") as $r | (.activity_type // "") as $t
      | select(($t | IN("force_push", "branch_deletion"))
               or (($a | IN($role_actors[])) and $r != $ref)
               or ($a == "github-actions[bot]" and $r != $ref and $r != $state_ref))
      | select(($a | IN($role_actors[])) or $a == "github-actions[bot]")
      | "\($t | if . == "" then "?" else . end) \($r | if . == "" then "?" else . end) \((.before // "") | .[0:12])..\((.after // "") | .[0:12]) by \($a) at \(.timestamp // "?")"'
    exit 0
  fi
  log "perimeter: the activity endpoint is unavailable (gh exit $rc) — comparing the refs now with the claim-time snapshot"
  # Never $RUN_DIR: in `advance` that directory is restored from the handoff artifact
  # the role itself uploaded, so a snapshot read from there is the role's own answer.
  snap=${REFS_SNAPSHOT:-.swarm-claim/refs-snapshot.txt}
  if [ ! -f "$snap" ]; then
    printf 'check-not-run refs-snapshot (none at %s) by unknown (activity endpoint unavailable)\n' "$snap"
    exit 0
  fi
  now=$(tmpf .now) && then_=$(tmpf .then) || die "perimeter: no temp dir"
  if ! refs_now "$now"; then
    printf 'check-not-run refs-now (neither the refs API nor git ls-remote answered) by unknown (activity endpoint unavailable)\n'
    rm -f "$now" "$then_"
    exit 0
  fi
  # keyed on the ref, value the sha, both sides sorted
  awk '{ print $2 "\t" $1 }' "$now" | LC_ALL=C sort > "$now.k"
  awk '{ print $2 "\t" $1 }' "$snap" 2>/dev/null | LC_ALL=C sort > "$then_.k"
  # -a 1 -a 2 reports both sides, so a DELETED ref is reported too. The state branch is
  # deliberately not skipped: rolling the signed state back to an older signed document
  # is a push to exactly that ref, and it is the one thing this check must not miss.
  join -t "$(printf '\t')" -a 1 -a 2 -e '(none)' -o '0,1.2,2.2' "$now.k" "$then_.k" \
    | awk -F'\t' -v skip="refs/heads/$branch" -v state="refs/heads/$state_branch" '
        $1 == skip || $1 == state || $1 ~ /^refs\/pull\// { next }
        $2 == $3 { next }
        { kind = "ref-changed"
          if ($3 == "(none)") kind = "ref-created"
          if ($2 == "(none)") kind = "ref-deleted"
          printf "%s %s %s..%s by unknown (activity endpoint unavailable)\n", kind, $1, substr($3, 1, 12), substr($2, 1, 12) }'
  rm -f "$now" "$then_" "$now.k" "$then_.k"
  exit 0
}

case ${1:-} in
  manifests) shift; cmd_manifests "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  activity) shift; cmd_activity "$@" ;;
  *) sed -n '2,38p' "$0" >&2; exit 1 ;;
esac
