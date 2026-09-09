#!/usr/bin/env bash
# run.sh — the conformance harness. Runs every case under lib/conformance/cases/<area>/<name>/
# against the fake GitHub (lib/sh/gh-shim.sh) and prints `N/N conformant`, or the
# failing names with a diff of expected vs actual; exit 1 on any failure.
#
#   lib/conformance/run.sh [--list] [--keep] [--verbose] [--trace] [area|area/case …]
#
#   --list      print the case names and stop
#   --keep      keep the per-case temp directories (paths printed)
#   --verbose   on failure also print the script's stdout, stderr and calls.log
#   --trace     print stdout/stderr/calls.log for every case
#
# A case directory holds:
#   case.json    required (below)
#   event.env    optional KEY=VALUE lines exported into the script's environment
#   state.json   optional initial state document WITHOUT `sig`; signed with the harness
#                key before it is served (absent = no state file, GET → 404)
#   fixtures/    optional extra shim answers, copied last (override the bundles)
#
# case.json:
#   {
#     "script": "lib/sh/resolve.sh",         // relative to the swarm root; cwd = a temp project checkout
#     "args": ["7"],                         // optional
#     "env": { "D_REASON": "chain" },        // optional, merged over event.env
#     "stdin": "text" | "@fixtures/x.txt",   // optional (path relative to lib/conformance/)
#     "fixtures": ["common", "state-running"],       // bundles from lib/conformance/fixtures/<name>/, in order
#     "project_files": { "REQS.md": "…", ".github/swarm.yml": "@fixtures/config/user-owned.yml" },
#     "commit_project_files": true,          // default true: the files are committed on main
#     "expect": {
#       "exit": 0,                                        // required
#       "outputs": { "go": "false", "reason": "*" },      // subset of $GITHUB_OUTPUT (jq-normalised; "*" = any)
#       "calls": [ "POST repos/o/r/issues/7/comments", "!DELETE repos/o/r/issues/7/labels/x" ],
#                 // ordered subsequence over calls.log's first column; "!P" asserts absence anywhere;
#                 // P may contain shell globs; "~text" matches a substring of the whole line (body included)
#                 // and may refine the line the previous pattern matched (e.g. a PUT, then "~dispatch-finished")
#       "state_after": { "status": "queued", "next.key": "7:build:code-review:app:1" },
#                 // dotted-path subset of the state file the shim holds at the end; its sig is verified
#       "state_issue": 7,                                 // which state file (default: state.json's .issue, then $ISSUE)
#       "stdout_contains": ["SKIP: …"],                   // substrings of stdout+stderr
#       "stdout_not_contains": ["ghs_"],                  // absent from stdout+stderr
#       "files": { ".swarm-run/result.json": "exists" }   // "exists" | "absent" | a substring, relative to the project
#     }
#   }
#
# Every case runs with: SWARM_FAKE_GH=<temp>, SWARM_STATE_KEY=<harness key>,
# GITHUB_OUTPUT=<temp file>, GITHUB_STEP_SUMMARY=/dev/null, RUNNER_TEMP=<temp>,
# GITHUB_RUN_ID=424242, GITHUB_RUN_ATTEMPT=1 (also RUN_ID/RUN_ATTEMPT), REPO=o/r,
# SWARM_ROOT=<swarm root>, GH_TOKEN=fake, cwd = a fresh `git init -b main` checkout with
# one commit. Fixtures are layered: fixtures/common/ → the case's bundles → the case's
# own fixtures/ → the signed state.json.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sh" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

CONF="$SWARM_ROOT/lib/conformance"
HARNESS_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
CASE_TIMEOUT=${SWARM_CASE_TIMEOUT:-120}
TMPBASE=${SWARM_TMP:-${TMPDIR:-/tmp}}

keep=0 verbose=0 trace=0 list=0
selectors=()
for a in "$@"; do
  case $a in
    --keep) keep=1 ;;
    --verbose|-v) verbose=1 ;;
    --trace) trace=1; verbose=1 ;;
    --list) list=1 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    -*) die "unknown option $a" ;;
    *) selectors+=("$a") ;;
  esac
done

# ── signing (state.sh when present, else the same HMAC inline) ─────────────────

hmac() { jq -S -c 'del(.sig)' | openssl dgst -sha256 -hmac "$HARNESS_KEY" | sed 's/^.* //'; }

sign_state() { # stdin → signed JSON
  if [ -x "$SWARM_LIB/state.sh" ]; then
    SWARM_STATE_KEY=$HARNESS_KEY "$SWARM_LIB/state.sh" sign
  else
    local doc sig
    doc=$(cat)
    sig=$(printf '%s' "$doc" | hmac)
    printf '%s' "$doc" | jq --arg sig "$sig" '. + {sig: $sig}'
  fi
}

verify_state() { # <file> → 0 when the sig matches
  local want got
  want=$(jq -r '.sig // empty' "$1")
  [ -n "$want" ] || return 1
  got=$(hmac < "$1")
  [ "$want" = "$got" ]
}

# ── case discovery ─────────────────────────────────────────────────────────────

cases=()
collect_cases() {
  local sel d
  if [ ${#selectors[@]} -eq 0 ]; then
    for d in "$CONF"/cases/*/*/; do
      [ -f "$d/case.json" ] && cases+=("${d%/}")
    done
    return
  fi
  for sel in "${selectors[@]}"; do
    sel=${sel#cases/}
    sel=${sel%/}
    if [ -f "$CONF/cases/$sel/case.json" ]; then
      cases+=("$CONF/cases/$sel")
    elif [ -d "$CONF/cases/$sel" ]; then
      for d in "$CONF/cases/$sel"/*/; do
        [ -f "$d/case.json" ] && cases+=("${d%/}")
      done
    else
      die "no such area or case: $sel"
    fi
  done
}
collect_cases
if [ ${#cases[@]} -eq 0 ]; then
  echo "0/0 conformant (no cases found)"
  exit 0
fi
if [ $list -eq 1 ]; then
  for c in "${cases[@]}"; do printf '%s\n' "${c#"$CONF"/cases/}"; done
  exit 0
fi

# ── helpers ─────────────────────────────────────────────────────────────────────

# normalise <value>: JSON-parseable text → canonical JSON; anything else → the raw text.
normalise() {
  local v=$1 j
  if j=$(printf '%s' "$v" | jq -S -c . 2>/dev/null); then printf '%s' "$j"; else printf '%s' "$v"; fi
}

# outputs_json <GITHUB_OUTPUT file> → {key: value} (heredoc values supported; last write wins)
outputs_json() {
  local file=$1 line k v delim
  local obj="{}"
  [ -f "$file" ] || { printf '%s' "$obj"; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      *"<<"*)
        k=${line%%<<*}
        delim=${line#*<<}
        v=""
        while IFS= read -r line && [ "$line" != "$delim" ]; do
          v+="${v:+$'\n'}$line"
        done
        ;;
      *=*)
        k=${line%%=*}
        v=${line#*=}
        ;;
      *) continue ;;
    esac
    obj=$(printf '%s' "$obj" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v')
  done < "$file"
  printf '%s' "$obj"
}

# path_to_jq "a.b.0.c" → ["a","b",0,"c"]
path_to_jq() {
  printf '%s' "$1" | jq -R -c 'split(".") | map(if test("^[0-9]+$") then tonumber else . end)'
}

# call_matches <pattern> <line>
call_matches() {
  local pat=$1 line=$2 col1=${2%%$'\t'*}
  # shellcheck disable=SC2053
  case $pat in
    "~"*) [[ $line == *"${pat#\~}"* ]] ;;
    *"*"*|*"?"*) [[ $col1 == $pat ]] ;;
    *) [ "$col1" = "$pat" ] ;;
  esac
}

fails=()
passes=0
total=${#cases[@]}

run_case() {
  local dir=$1 name=${1#"$CONF"/cases/} cj="$1/case.json"
  local problems=()
  problem() { problems+=("$1"); }

  local tmp fake proj outf rtemp script rc
  tmp=$(mktemp -d "$TMPBASE/swarm-conf.XXXXXX") || die "cannot create a temp dir under $TMPBASE"
  fake="$tmp/gh"
  proj="$tmp/project"
  rtemp="$tmp/runner-temp"
  outf="$tmp/github-output"
  mkdir -p "$fake" "$proj" "$rtemp"
  : > "$outf"

  jq -e . "$cj" >/dev/null 2>&1 || { problem "case.json is not valid JSON"; report_case "$name" "$tmp" problems; return; }
  script=$(jq -r '.script // empty' "$cj")
  [ -n "$script" ] || problem "case.json: script is required"
  [ -n "$script" ] && [ ! -x "$SWARM_ROOT/$script" ] && problem "script not found or not executable: $script"
  jq -e '.expect | type == "object" and has("exit")' "$cj" >/dev/null 2>&1 || problem "case.json: expect.exit is required"
  if [ ${#problems[@]} -gt 0 ]; then report_case "$name" "$tmp" problems; return; fi

  # fixtures: common → bundles → the case's own
  local b
  [ -d "$CONF/fixtures/common" ] && cp -r "$CONF/fixtures/common/." "$fake/"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ -d "$CONF/fixtures/$b" ]; then cp -r "$CONF/fixtures/$b/." "$fake/"; else problem "fixture bundle not found: $b"; fi
  done < <(jq -r '.fixtures // [] | .[]' "$cj")
  [ -d "$dir/fixtures" ] && cp -r "$dir/fixtures/." "$fake/"
  rm -f "$fake/calls.log"
  mkdir -p "$fake/state"

  # the state document, signed with the harness key
  local issue=""
  issue=$(jq -r '.expect.state_issue // empty' "$cj")
  if [ -f "$dir/state.json" ]; then
    local n
    n=$(jq -r '.issue // empty' "$dir/state.json")
    [ -n "$issue" ] || issue=$n
    [ -n "$n" ] || n=$issue
    if [ -z "$n" ]; then
      problem "state.json has no .issue and expect.state_issue is unset"
    else
      sign_state < "$dir/state.json" > "$fake/state/issues-$n.json" || problem "cannot sign state.json"
    fi
  fi

  # the project checkout
  (
    cd "$proj" || exit 1
    git init -q -b main . \
      && git -c user.name=swarm-harness -c user.email=harness@example.invalid commit -q --allow-empty -m "init" \
      && printf '# project\n' > README.md && git add README.md \
      && git -c user.name=swarm-harness -c user.email=harness@example.invalid commit -q -m "README"
  ) || problem "cannot create the project checkout"
  local pf src content
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    content=$(jq -r --arg k "$pf" '.project_files[$k]' "$cj")
    mkdir -p "$proj/$(dirname "$pf")"
    case $content in
      "@"*)
        src="$CONF/${content#@}"
        if [ -f "$src" ]; then cp "$src" "$proj/$pf"; else problem "project_files: $content not found under lib/conformance/"; fi ;;
      *) printf '%s' "$content" > "$proj/$pf" ;;
    esac
  done < <(jq -r '.project_files // {} | keys[]' "$cj")
  if jq -e '.commit_project_files // true' "$cj" >/dev/null && jq -e '(.project_files // {}) | length > 0' "$cj" >/dev/null; then
    ( cd "$proj" && git add -A && git -c user.name=swarm-harness -c user.email=harness@example.invalid commit -q -m "case files" ) \
      || problem "cannot commit project_files"
  fi

  # environment
  local envf="$tmp/env.sh" line
  {
    printf 'export SWARM_FAKE_GH=%q SWARM_STATE_KEY=%q GITHUB_OUTPUT=%q GITHUB_STEP_SUMMARY=/dev/null RUNNER_TEMP=%q\n' "$fake" "$HARNESS_KEY" "$outf" "$rtemp"
    printf 'export GITHUB_RUN_ID=424242 GITHUB_RUN_ATTEMPT=1 RUN_ID=424242 RUN_ATTEMPT=1 REPO=o/r SWARM_ROOT=%q GH_TOKEN=fake\n' "$SWARM_ROOT"
    printf 'export SWARM_RETRY_SLEEP=0 SWARM_FIRE_SLEEP=0 GITHUB_ENV=%q\n' "$tmp/github-env"
    if [ -f "$dir/event.env" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case $line in
          ''|'#'*) continue ;;
          *=*) printf 'export %q\n' "$line" ;;
        esac
      done < "$dir/event.env"
    fi
    jq -r '.env // {} | to_entries[] | "export " + (.key + "=" + (.value | if type == "string" then . else tojson end) | @sh)' "$cj"
  } > "$envf"
  : > "$tmp/github-env"

  # stdin
  local stdinf="$tmp/stdin" s
  : > "$stdinf"
  s=$(jq -r '.stdin // empty' "$cj")
  case $s in
    "") ;;
    "@"*) if [ -f "$CONF/${s#@}" ]; then cp "$CONF/${s#@}" "$stdinf"; else problem "stdin: $s not found"; fi ;;
    *) printf '%s' "$s" > "$stdinf" ;;
  esac

  # run
  local -a args=()
  while IFS= read -r -d '' line; do args+=("$line"); done < <(jq -j '.args // [] | .[] | . + "\u0000"' "$cj")
  (
    cd "$proj" || exit 97
    # shellcheck disable=SC1090
    . "$envf"
    exec timeout "$CASE_TIMEOUT" "$SWARM_ROOT/$script" "${args[@]}" < "$stdinf" > "$tmp/stdout" 2> "$tmp/stderr"
  )
  rc=$?
  [ $rc -eq 124 ] && problem "timed out after ${CASE_TIMEOUT}s"

  # ── expectations ──
  local want
  want=$(jq -r '.expect.exit' "$cj")
  [ "$rc" = "$want" ] || problem "exit: expected $want, got $rc"

  local outs k ev av
  outs=$(outputs_json "$outf")
  while IFS= read -r k; do
    ev=$(jq -r --arg k "$k" '.expect.outputs[$k] | if type == "string" then . else tojson end' "$cj")
    if ! printf '%s' "$outs" | jq -e --arg k "$k" 'has($k)' >/dev/null; then
      problem "outputs.$k: expected $(printf '%s' "$ev" | jq -R .), but the output was never written"
      continue
    fi
    av=$(printf '%s' "$outs" | jq -r --arg k "$k" '.[$k]')
    [ "$ev" = "*" ] && continue
    [ "$(normalise "$ev")" = "$(normalise "$av")" ] || problem "outputs.$k: expected $(printf '%s' "$ev" | jq -R .), got $(printf '%s' "$av" | jq -R .)"
  done < <(jq -r '.expect.outputs // {} | keys[]' "$cj")

  local -a loglines=()
  [ -f "$fake/calls.log" ] && mapfile -t loglines < "$fake/calls.log"
  local pat cursor=0 i found
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if [ "${pat#!}" != "$pat" ]; then
      for i in "${!loglines[@]}"; do
        if call_matches "${pat#!}" "${loglines[$i]}"; then
          problem "calls: \"${pat#!}\" must not appear, but line $((i + 1)) is: ${loglines[$i]%%$'\t'*}"
          break
        fi
      done
      continue
    fi
    found=0
    # a "~" pattern may refine the line the previous pattern matched; a plain
    # pattern must match a later line
    if [ "${pat#\~}" != "$pat" ] && [ $cursor -gt 0 ]; then i=$((cursor - 1)); else i=$cursor; fi
    while [ $i -lt ${#loglines[@]} ]; do
      if call_matches "$pat" "${loglines[$i]}"; then found=1; cursor=$((i + 1)); break; fi
      i=$((i + 1))
    done
    [ $found -eq 1 ] || problem "calls: \"$pat\" not found after line $cursor of calls.log (${#loglines[@]} lines)"
  done < <(jq -r '.expect.calls // [] | .[]' "$cj")

  if jq -e '.expect.state_after | type == "object"' "$cj" >/dev/null 2>&1; then
    local sf="$fake/state/issues-$issue.json" p jp
    if [ -z "$issue" ]; then
      problem "state_after: which issue? set expect.state_issue (no state.json and no .issue)"
    elif [ ! -f "$sf" ]; then
      problem "state_after: no state file for issue $issue at the end"
    elif ! jq -e . "$sf" >/dev/null 2>&1; then
      problem "state_after: the state file is not valid JSON"
    else
      verify_state "$sf" || problem "state_after: signature invalid — the state was written unsigned or with a foreign key"
      while IFS= read -r p; do
        jp=$(path_to_jq "$p")
        ev=$(jq -c --arg k "$p" '.expect.state_after[$k]' "$cj")
        av=$(jq -c --argjson p "$jp" 'getpath($p)' "$sf" 2>/dev/null) || av="null"
        if [ "$ev" = '"*"' ]; then
          [ "$av" != "null" ] || problem "state_after.$p: expected any value, got null"
          continue
        fi
        [ "$(normalise "$ev")" = "$(normalise "$av")" ] || problem "state_after.$p: expected $ev, got $av"
      done < <(jq -r '.expect.state_after | keys[]' "$cj")
    fi
  fi

  local combined="$tmp/combined" sub
  cat "$tmp/stdout" "$tmp/stderr" > "$combined"
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    grep -qF -- "$sub" "$combined" || problem "stdout_contains: $(printf '%s' "$sub" | jq -R .) not found in stdout+stderr"
  done < <(jq -r '.expect.stdout_contains // [] | .[]' "$cj")
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    ! grep -qF -- "$sub" "$combined" || problem "stdout_not_contains: $(printf '%s' "$sub" | jq -R .) is present in stdout+stderr"
  done < <(jq -r '.expect.stdout_not_contains // [] | .[]' "$cj")

  local f how
  while IFS= read -r f; do
    how=$(jq -r --arg k "$f" '.expect.files[$k]' "$cj")
    case $how in
      exists) [ -e "$proj/$f" ] || problem "files: $f should exist" ;;
      absent) [ ! -e "$proj/$f" ] || problem "files: $f should be absent" ;;
      *) { [ -f "$proj/$f" ] && grep -qF -- "$how" "$proj/$f"; } || problem "files: $f should contain $(printf '%s' "$how" | jq -R .)" ;;
    esac
  done < <(jq -r '.expect.files // {} | keys[]' "$cj")

  report_case "$name" "$tmp" problems
}

report_case() { # <name> <tmp> <problems-array-name>
  local name=$1 tmp=$2
  local -n probs=$3
  if [ ${#probs[@]} -eq 0 ]; then
    passes=$((passes + 1))
    printf '  ok    %s\n' "$name"
    [ $trace -eq 1 ] && dump_case "$tmp"
  else
    fails+=("$name")
    printf '  FAIL  %s\n' "$name"
    local p
    for p in "${probs[@]}"; do printf '        - %s\n' "$p"; done
    [ $verbose -eq 1 ] && dump_case "$tmp"
  fi
  if [ $keep -eq 1 ]; then
    printf '        kept: %s\n' "$tmp"
  else
    rm -rf "$tmp"
  fi
}

dump_case() {
  local tmp=$1
  printf '        --- stdout ---\n'; sed 's/^/        | /' "$tmp/stdout" 2>/dev/null
  printf '        --- stderr ---\n'; sed 's/^/        | /' "$tmp/stderr" 2>/dev/null
  printf '        --- GITHUB_OUTPUT ---\n'; sed 's/^/        | /' "$tmp/github-output" 2>/dev/null
  printf '        --- calls.log ---\n'
  if [ -f "$tmp/gh/calls.log" ]; then
    awk -F'\t' '{ b = $2; if (length(b) > 160) b = substr(b, 1, 160) "…"; printf "        | %d %s\t%s\n", NR, $1, b }' "$tmp/gh/calls.log"
  fi
}

for c in "${cases[@]}"; do
  run_case "$c"
done

echo
if [ ${#fails[@]} -eq 0 ]; then
  echo "$passes/$total conformant"
  exit 0
fi
echo "$passes/$total conformant — failing: $(printf '%s, ' "${fails[@]}" | sed 's/, $//')"
exit 1
