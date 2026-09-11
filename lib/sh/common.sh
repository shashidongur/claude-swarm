#!/usr/bin/env bash
# Shared helpers for every lib/sh script. Source it, never run it:
#
#   SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SWARM_LIB/common.sh"
#
# Scripts run with `set -uo pipefail` and never `-e`: a refusal is `say`, a hard
# failure is `die`. Bodies from events go env -> file -> grep; nothing untrusted is
# ever interpolated into a command line. When SWARM_FAKE_GH is set, `gh` resolves to
# lib/sh/gh-shim.sh so the conformance harness can run every script without GitHub.
#
# Environment the helpers read (all optional unless a helper says otherwise):
#   REPO           owner/repo (post_comment, find_comment, default_branch, ...)
#   ISSUE          default issue number for `marker`
#   OWNER          repository owner login (approvers_for fallback)
#   CONFIG_JSON    path to the loaded config (approvers_for, default_branch)
#   STATE_JSON     path to the current state document (reply honours `refusals`, G38)
#   WORKFLOW_REF   github.workflow_ref (stub_file)
#   GITHUB_OUTPUT  where `out`/`say` write step outputs
#   SWARM_NOW      fixed timestamp for snapshot tests (`now`)
#   SWARM_RETRY_SLEEP  seconds between gh_json retries (default 3)

if [ -z "${SWARM_LIB:-}" ]; then
  SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export SWARM_LIB
if [ -z "${SWARM_ROOT:-}" ]; then
  SWARM_ROOT="$(cd "$SWARM_LIB/../.." && pwd)"
fi
export SWARM_ROOT

# ── logging, outputs, exits ────────────────────────────────────────────────────

log() { printf '%s\n' "$*" >&2; }

# out <key> <value>: append a step output; multi-line values use the heredoc form.
out() {
  local k=$1 v=${2-}
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  if [ "${v#*$'\n'}" != "$v" ]; then
    local d="SWARMEOF_$RANDOM$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$k" "$d" "$v" "$d" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  fi
}

# say <reason> [block]: a refusal. go=false, the reason, an optional blocked:* label;
# exit 0 — a refused dispatch is not a broken workflow.
say() {
  out go false
  out reason "$1"
  out block "${2:-}"
  printf 'SKIP: %s\n' "$1"
  exit 0
}

# die <msg>: the accepted hard failures only (cannot read state or thread, five CAS
# conflicts, a fire with no verified run).
die() {
  printf '::error::%s\n' "$*"
  exit 1
}

now() { printf '%s\n' "${SWARM_NOW:-$(date -u +%FT%TZ)}"; }

# tmpf [suffix]: a temp file under RUNNER_TEMP when set.
tmpf() { mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swarm.XXXXXX${1:-}"; }

require_env() {
  local n
  for n in "$@"; do
    [ -n "${!n:-}" ] || die "missing environment: $n"
  done
}

# ── gh ─────────────────────────────────────────────────────────────────────────

gh() {
  if [ -n "${SWARM_FAKE_GH:-}" ]; then
    "$SWARM_LIB/gh-shim.sh" "$@"
  else
    command gh "$@"
  fi
}

# gh_json <gh api args…>: `gh api` with three retries on 5xx. With --paginate and no
# --jq the pages (one JSON document each) are merged into one array/object.
gh_json() {
  local a paginate=0 hasjq=0 try rc err outf
  for a in "$@"; do
    case $a in
      --paginate) paginate=1 ;;
      --jq|-q|--jq=*) hasjq=1 ;;
    esac
  done
  err=$(tmpf) || return 1
  outf=$(tmpf) || return 1
  rc=1
  for try in 1 2 3 4; do
    gh api "$@" > "$outf" 2> "$err"
    rc=$?
    [ $rc -eq 0 ] && break
    if grep -qE 'HTTP 5[0-9][0-9]' "$err" && [ $try -lt 4 ]; then
      log "gh api $*: $(head -c 200 "$err") — retry $try"
      sleep $(( ${SWARM_RETRY_SLEEP:-3} * try ))
      continue
    fi
    break
  done
  if [ $rc -ne 0 ]; then
    cat "$err" >&2
    rm -f "$err" "$outf"
    return $rc
  fi
  if [ $paginate -eq 1 ] && [ $hasjq -eq 0 ]; then
    jq -s 'if length == 0 then null elif length == 1 then .[0] elif all(type == "array") then add else . end' "$outf"
  else
    cat "$outf"
  fi
  rm -f "$err" "$outf"
  return 0
}

# ── markers (§11.2) ─────────────────────────────────────────────────────────────

# marker <kind> k=v…  → "<!-- swarm: v2 | kind=… | issue=… | … | at=… -->"
# Field order is fixed; values are restricted to [A-Za-z0-9:._/-] (other bytes become
# "_"). `issue` defaults to $ISSUE, `at` to `now`.
marker() {
  local kind=$1 kv k v clean line
  shift
  local -A fields=()
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    case $k in
      kind|issue|stage|role|attempt|key|run|status|verdict|head|model|gate|event|topic|at) fields[$k]=$v ;;
      *) die "marker: unknown field '$k'" ;;
    esac
  done
  fields[kind]=$kind
  [ -n "${fields[issue]:-}" ] || fields[issue]=${ISSUE:-}
  [ -n "${fields[issue]:-}" ] || die "marker: issue is required"
  [ -n "${fields[at]:-}" ] || fields[at]=$(now)
  line="<!-- swarm: v2"
  for k in kind issue stage role attempt key run status verdict head model gate event topic at; do
    v=${fields[$k]:-}
    [ -n "$v" ] || continue
    clean=$(printf '%s' "$v" | tr -c 'A-Za-z0-9:._/-' '_')
    line+=" | $k=$clean"
  done
  printf '%s -->\n' "$line"
}

# marker_get <field> < body: the field's value from the first v2 marker in the body.
marker_get() {
  local f=$1
  grep -oE '<!-- swarm: v2 [^>]*-->' | head -1 | sed -E 's/ *-->$//' | tr '|' '\n' \
    | sed -n -E "s/^ *$f=([A-Za-z0-9:._/-]+) *$/\1/p" | head -1
}

# marker_pred <kind> [k=v…]: a jq predicate (over a comment object) matching a v2
# marker with that kind and those exact field values — for find_comment.
marker_pred() {
  local kind=$1 kv k v p
  shift
  p="(.body | test(\"[|] kind=$kind( [|]| -->)\"))"
  for kv in "$@"; do
    k=${kv%%=*}
    v=$(printf '%s' "${kv#*=}" | sed -e 's/[.]/[.]/g')
    p+=" and (.body | test(\"[|] $k=$v( [|]| -->)\"))"
  done
  printf '%s' "$p"
}

# ── comments ────────────────────────────────────────────────────────────────────

# find_comment <issue> <jq-predicate> [preferred_id]: the newest comment on the
# thread authored by github-actions[bot] that carries a v2 marker and satisfies the
# predicate, as one JSON object; empty + exit 1 when none. A preferred id (e.g.
# state.state_comment_id) is tried first. An unreadable thread is G3: die.
find_comment() {
  local issue=$1 pred=$2 pref=${3:-} c all
  if [ -n "$pref" ] && [ "$pref" != "null" ] && [ "$pref" != "0" ]; then
    if c=$(gh api "repos/$REPO/issues/comments/$pref" 2>/dev/null); then
      if printf '%s' "$c" | jq -e 'select(.user.login == "github-actions[bot]") | select(.body | contains("<!-- swarm: v2")) | select('"$pred"')' >/dev/null 2>&1; then
        printf '%s' "$c" | jq -c .
        return 0
      fi
    fi
  fi
  all=$(gh_json --paginate "repos/$REPO/issues/$issue/comments") \
    || die "cannot list comments of #$issue — refusing to guess"
  c=$(printf '%s' "$all" | jq -c '[.[] | select(.user.login == "github-actions[bot]") | select(.body | contains("<!-- swarm: v2")) | select('"$pred"')] | last // empty')
  [ -n "$c" ] || return 1
  printf '%s\n' "$c"
}

# Bodies posted by the dispatcher pass through redact (never a token) and through a
# marker-preserving comment neutraliser: any `<!--`/`-->` that is not a whole,
# well-formed v2 marker line is defused, so a role-provided string that survived the
# renderer can still not plant a marker. Handles are the renderer's job (`sanitize`):
# the gate comment's approver mention is the one legitimate `@`.
_prepare_body() {
  local zw=$'​'
  redact | awk -v zw="$zw" '
    /^<!-- swarm: v2 \| kind=[a-z]+ \| .* \| at=[0-9TZ:.-]+ -->$/ { print; next }
    { gsub(/<!--/, "<!-" zw "-"); gsub(/-->/, "-" zw "->"); print }'
}

# post_comment <issue> <file>: prints the new comment id.
post_comment() {
  local issue=$1 file=$2 body id
  body=$(tmpf .md) || return 1
  _prepare_body < "$file" > "$body"
  id=$(gh api -X POST "repos/$REPO/issues/$issue/comments" -F body=@"$body" --jq .id) || {
    rm -f "$body"
    return 1
  }
  rm -f "$body"
  printf '%s\n' "$id"
}

# edit_comment <comment_id> <file>
edit_comment() {
  local id=$1 file=$2 body
  body=$(tmpf .md) || return 1
  _prepare_body < "$file" > "$body"
  gh api -X PATCH "repos/$REPO/issues/comments/$id" -F body=@"$body" --jq .id >/dev/null || {
    rm -f "$body"
    return 1
  }
  rm -f "$body"
}

# reply <issue> <event_id> <text> [refusal_login]: one dispatcher reply per event id
# (skip-if-exists: a re-run finds `kind=reply | event=<id>` and logs "already
# replied"). With a refusal login, G38 applies: when $STATE_JSON records a refusal
# reply to that login today, nothing is posted (the caller records the refusal with
# the `refusal` transition). Prints the comment id when one exists.
reply() {
  local issue=$1 event=$2 text=$3 login=${4:-} existing today body id
  [ -n "$event" ] || event="run-${RUN_ID:-${GITHUB_RUN_ID:-0}}"
  if existing=$(find_comment "$issue" "$(marker_pred reply "event=$event")"); then
    id=$(printf '%s' "$existing" | jq -r .id)
    log "already replied to event $event (comment $id)"
    printf '%s\n' "$id"
    return 0
  fi
  if [ -n "$login" ] && [ -n "${STATE_JSON:-}" ] && [ -f "$STATE_JSON" ]; then
    today=$(now | cut -c1-10)
    if jq -e --arg l "$login" --arg d "$today" '.refusals[$l] == $d' "$STATE_JSON" >/dev/null 2>&1; then
      log "refusal reply to $login already sent today (G38) — silent"
      return 0
    fi
  fi
  body=$(tmpf .md) || return 1
  {
    printf '🧭 **dispatch** · reply — %s\n' "$(printf '%s' "$text" | sanitize)"
    marker reply "issue=$issue" "event=$event"
  } > "$body"
  id=$(post_comment "$issue" "$body") || {
    rm -f "$body"
    return 1
  }
  rm -f "$body"
  printf '%s\n' "$id"
}

# ── sanitisation, fencing, redaction ───────────────────────────────────────────

# sanitize: stdin → stdout. `<!--` → `<!-​-`, `-->` → `-​->`, `@x` → `@​x` (zero-width
# space), so a role-provided string can never carry a marker or a mention. Delegates
# to lib/jq/sanitize.jq when it is present and passes a self-check; sed otherwise.
_SANITIZE_MODE=""
_sanitize_probe() {
  local zw=$'​' f=$1 got
  got=$(printf '<!--' | jq -Rrs -f "$f" 2>/dev/null) || return 1
  [ "$got" = "<!-${zw}-" ]
}
sanitize() {
  local zw=$'​' f="$SWARM_ROOT/lib/jq/sanitize.jq"
  if [ -z "$_SANITIZE_MODE" ]; then
    if [ -f "$f" ] && _sanitize_probe "$f"; then _SANITIZE_MODE="jq"; else _SANITIZE_MODE="sed"; fi
  fi
  if [ "$_SANITIZE_MODE" = jq ]; then
    jq -Rrs -f "$f"
  else
    sed -E -e "s/<!--/<!-${zw}-/g" -e "s/-->/-${zw}->/g" -e "s/@([A-Za-z0-9-])/@${zw}\\1/g"
  fi
}

fence() { "$SWARM_LIB/fence.sh" "$@"; }

redact() { "$SWARM_LIB/redact.sh"; }

# ── repository facts ───────────────────────────────────────────────────────────

# stub_file: the project's dispatch stub, from github.workflow_ref
# (owner/repo/.github/workflows/<file>@refs/heads/main) or $STUB_FILE.
stub_file() {
  local ref=${WORKFLOW_REF:-}
  if [ -n "$ref" ]; then
    basename "${ref%%@*}"
    return 0
  fi
  if [ -n "${STUB_FILE:-}" ]; then
    printf '%s\n' "$STUB_FILE"
    return 0
  fi
  return 1
}

_SWARM_DEFAULT_BRANCH=""
default_branch() {
  if [ -n "$_SWARM_DEFAULT_BRANCH" ]; then
    printf '%s\n' "$_SWARM_DEFAULT_BRANCH"
    return 0
  fi
  local b=""
  if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then
    b=$(jq -r '.default_branch // empty' "$CONFIG_JSON" 2>/dev/null)
  fi
  if [ -z "$b" ] && [ -n "${DEFAULT_BRANCH:-}" ]; then b=$DEFAULT_BRANCH; fi
  if [ -z "$b" ]; then
    b=$(gh api "repos/$REPO" --jq .default_branch 2>/dev/null) || b=""
  fi
  [ -n "$b" ] || return 1
  _SWARM_DEFAULT_BRANCH=$b
  printf '%s\n' "$b"
}

declare -A _SWARM_OWNER_TYPE=()
# owner_type <login>: "User" | "Organization" (empty + exit 1 when unreadable).
owner_type() {
  local login=$1 t
  if [ -n "${_SWARM_OWNER_TYPE[$login]:-}" ]; then
    printf '%s\n' "${_SWARM_OWNER_TYPE[$login]}"
    return 0
  fi
  t=$(gh api "users/$login" --jq .type 2>/dev/null) || t=""
  [ -n "$t" ] || return 1
  _SWARM_OWNER_TYPE[$login]=$t
  printf '%s\n' "$t"
}

# approvers_for <gate>: one login per line. `approvers.<gate>` when set, else
# `approvers.default`, else the repository owner on a user-owned repo; empty (exit 1)
# on an org-owned repo without config (§6.2). `budget` and every non-gate verb use
# the default list.
approvers_for() {
  local gate=${1:-default} list owner
  case $gate in
    requirements|architecture|release|confidence) ;;
    *) gate=default ;;
  esac
  list=""
  if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then
    list=$(jq -r --arg g "$gate" '
      def nonempty: if type == "array" and length > 0 then . else empty end;
      ((.approvers[$g] // empty | nonempty) // (.approvers.default // empty | nonempty) // []) | .[]' "$CONFIG_JSON" 2>/dev/null)
  fi
  if [ -n "$list" ]; then
    printf '%s\n' "$list"
    return 0
  fi
  owner=${OWNER:-${REPO%%/*}}
  [ -n "$owner" ] || return 1
  if [ "$(owner_type "$owner")" = "User" ]; then
    printf '%s\n' "$owner"
    return 0
  fi
  return 1
}

# is_approver <login> <gate>
is_approver() {
  local login=$1 gate=${2:-default}
  [ -n "$login" ] || return 1
  approvers_for "$gate" | grep -qixF -- "$login"
}

# ── strings ─────────────────────────────────────────────────────────────────────

# slugify: stdin (or $1) → kebab-case, ≤ 40 chars, never a leading/trailing dash.
slugify() {
  local s
  if [ $# -gt 0 ]; then s=$1; else s=$(cat); fi
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40 | sed -E 's/-+$//'
  printf '\n'
}

# matches_glob <path> <glob…>: exit 0 when the path matches any glob. Globs are
# anchored and translated to an ERE: `**/` → any directory prefix (including none),
# `/**` at the end → the directory and everything below, `**` → anything, `*` → one
# path segment or part of it, `?` → one character; everything else is literal.
_glob_to_ere() {
  local g=$1 re="" i c n
  n=${#g}
  i=0
  while [ $i -lt $n ]; do
    c=${g:$i:1}
    if [ "$c" = "*" ] && [ "${g:$((i+1)):1}" = "*" ]; then
      if [ "${g:$((i+2)):1}" = "/" ]; then
        re+="(.*/)?"
        i=$((i+3))
        continue
      fi
      if [ $i -gt 0 ] && [ "${g:$((i-1)):1}" = "/" ] && [ $((i+2)) -eq $n ]; then
        re="${re%/}(/.*)?"
        i=$((i+2))
        continue
      fi
      re+=".*"
      i=$((i+2))
      continue
    fi
    case $c in
      '*') re+="[^/]*" ;;
      '?') re+="[^/]" ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'\') re+="\\$c" ;;
      *) re+="$c" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$re"
}
matches_glob() {
  local path=$1 g re
  shift
  path=${path#./}
  for g in "$@"; do
    [ -n "$g" ] || continue
    re=$(_glob_to_ere "$g")
    if [[ $path =~ ^${re}$ ]]; then return 0; fi
  done
  return 1
}

# ── runs, config, yaml ─────────────────────────────────────────────────────────

# evidence_hoist <dir>: after `gh run download <id> -D <dir>` (all artifacts of the run,
# each in <dir>/<artifact-name>/) lift the evidence artifact's files to <dir>/ — the one
# whose subdirectory holds a manifest.json and whose name is not a `*-partial*`
# intermediate (the evidence contract: exactly one artifact per run carries the
# manifest). A download that already put manifest.json at <dir>/ is left alone.
evidence_hoist() {
  local dir=$1 sub
  [ -d "$dir" ] || return 0
  [ -f "$dir/manifest.json" ] && return 0
  for sub in "$dir"/*/; do
    [ -d "$sub" ] || continue
    case ${sub%/} in *-partial*) continue ;; esac
    [ -f "$sub/manifest.json" ] || continue
    ( shopt -s dotglob nullglob; mv -- "$sub"* "$dir"/ ) && rmdir -- "$sub" 2>/dev/null
    return 0
  done
  return 0
}

# job_minutes <run_id>: Σ ceil((completed − started)/60 s) over the run's jobs — the
# billed minutes; jobs that never started or finished count 0.
job_minutes() {
  local id=$1 m
  local -a repo=()
  [ -n "${REPO:-}" ] && repo=(-R "$REPO")
  m=$(gh run view "${repo[@]}" "$id" --json jobs --jq '
    [ .jobs[]? | select(.startedAt != null and .completedAt != null)
      | ((((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)) / 60) | ceil) ]
    | add // 0' 2>/dev/null) || m=""
  printf '%s\n' "${m:-0}"
}

# yaml2json: stdin YAML → stdout JSON. mikefarah yq when it works, else PyYAML.
yaml2json() {
  local in outp
  in=$(tmpf .yml) || return 1
  cat > "$in"
  if command -v yq >/dev/null 2>&1; then
    if outp=$(yq -o=json . "$in" 2>/dev/null) && printf '%s' "$outp" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$outp"
      rm -f "$in"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    if outp=$(python3 -c 'import sys,json,yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)' < "$in" 2>/dev/null); then
      printf '%s\n' "$outp"
      rm -f "$in"
      return 0
    fi
  fi
  rm -f "$in"
  log "yaml2json: neither yq nor python3+PyYAML could parse the document"
  return 1
}
