#!/usr/bin/env bash
# state.sh — the signed, compare-and-swapped state document (spec §4.1, §16.1.3).
#
#   state.sh init-branch <owner/repo>            create the orphan state branch (idempotent)
#   state.sh branch-exists <owner/repo>          exit 0 when the state branch exists
#   state.sh read <issue> [--sha-file F]         print the verified document; the blob sha goes
#                                                to fd 3 when open, to F, and to $STATE_SHA_FILE
#                                                exit 3 absent · 6 bad/missing sig · 1 other API error
#   state.sh sign      < json > signed-json      sig = HMAC-SHA256(SWARM_STATE_KEY, jq -S -c 'del(.sig)')
#   state.sh verify    < json                    exit 0 when sig verifies, 6 otherwise
#   state.sh create <issue> <json-file>          sign + PUT without sha; exit 7 (and print the
#                                                existing document) when the file already exists
#   state.sh write <issue> <transition> [--arg k v]… [--argjson k json]… [--rawfile k file]… [--message m]
#                                                read → verify → apply lib/jq/transitions/<t>.jq → sign
#                                                → PUT with sha; conflict → re-read and re-apply (≤ 5,
#                                                then die); precondition error → exit 5 "state moved on";
#                                                an unchanged document is not written. Prints the new
#                                                document (exit 0), the reason on stderr otherwise.
#   state.sh apply <json-file|-> <transition> [--arg …]   the same, offline (no GitHub); `-` = stdin,
#                                                `null` for `start`
#   state.sh stage-pending <issue> <local-file> [<name>]  upload under issues/<N>/pending/<name>
#                                                (default: basename) and record {file, sha256}
#   state.sh copy-pending <issue> <dir>          download every recorded pending file into <dir>,
#                                                verifying its sha256 (mismatch → exit 8, nothing
#                                                written for that file); never deletes anything
#   state.sh clear-pending <issue> <name>        delete the staged file and drop its entry (after V7)
#   state.sh next-key <json-file> <stage> <role> <issue>:<stage>:<role>:<attempts[role]+1> — a counter
#   state.sh render <json-file> [--out F]        the state comment (lib/jq/render-state.jq)
#   state.sh sync-comment <issue> [<json-file>]  edit (or post) the kind=state comment; prints its id
#   state.sh month-totals <owner/repo> [YYYY-MM] {month, runner_minutes, overhead_minutes, minutes, cost_usd, issues[]}
#                                                over the state files touched that month (G31 fallback)
#   state.sh billing-used <owner>                total_minutes_used from the billing endpoint with
#                                                SWARM_TOKEN; empty when refused or unset (exit 0)
#   state.sh resign-all <owner/repo>             re-sign every issues/*.json with the current key
#
# Environment: REPO (or the <owner/repo> argument), SWARM_STATE_KEY (required for sign,
# verify, read, create, write), STATE_BRANCH (default: config state_branch, else
# swarm/state), RUN_ID / GITHUB_RUN_ID (passed to transitions as $run_id), SWARM_NOW.
# Every transition gets --arg now and --arg run_id unless the caller passes them.
# SWARM_STATE_RACE_HOOK (honoured only under the conformance shim, SWARM_FAKE_GH): a
# command run between the read and the PUT of every write attempt, so the harness can
# inject a concurrent writer and exercise the real CAS retry.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

TRANSITIONS="$SWARM_ROOT/lib/jq/transitions"
MAX_ATTEMPTS=5

state_branch() {
  local b=""
  if [ -n "${STATE_BRANCH:-}" ]; then b=$STATE_BRANCH
  elif [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then b=$(jq -r '.state_branch // empty' "$CONFIG_JSON" 2>/dev/null)
  fi
  printf '%s\n' "${b:-swarm/state}"
}

need_key() {
  [ -n "${SWARM_STATE_KEY:-}" ] || die "SWARM_STATE_KEY is empty — refusing to sign or verify state"
}

need_repo() {
  [ -n "${REPO:-}" ] || die "REPO is not set"
}

hmac_of() { # stdin: a JSON document → the hex HMAC over its canonical form without sig
  jq -S -c 'del(.sig)' | openssl dgst -sha256 -hmac "$SWARM_STATE_KEY" | sed 's/^.* //'
}

# ── sign / verify ──────────────────────────────────────────────────────────────

cmd_sign() {
  need_key
  local doc sig
  doc=$(cat)
  printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 || die "sign: stdin is not a JSON object"
  sig=$(printf '%s' "$doc" | hmac_of) || die "sign: HMAC failed"
  printf '%s' "$doc" | jq --arg sig "$sig" '. + {sig: $sig}'
}

verify_doc() { # <file> → 0 ok, 6 bad
  local want got
  want=$(jq -r '.sig // empty' "$1" 2>/dev/null)
  [ -n "$want" ] || return 6
  got=$(hmac_of < "$1") || return 6
  [ "$want" = "$got" ] || return 6
  return 0
}

cmd_verify() {
  need_key
  local f
  f=$(tmpf .json) || die "verify: no temp dir"
  cat > "$f"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { rm -f "$f"; log "verify: not a JSON object"; exit 6; }
  if verify_doc "$f"; then rm -f "$f"; exit 0; fi
  rm -f "$f"
  log "verify: signature missing or mismatching"
  exit 6
}

# ── the Contents API ────────────────────────────────────────────────────────────

# fetch_file <path> <doc-out> <sha-out>: 0 ok, 3 absent (404), 1 other error (stderr kept)
fetch_file() {
  local path=$1 docf=$2 shaf=$3 raw err rc
  err=$(tmpf .err) || return 1
  raw=$(gh api "repos/$REPO/contents/$path?ref=$(state_branch)" 2> "$err")
  rc=$?
  if [ $rc -ne 0 ]; then
    if grep -qE 'HTTP 404' "$err"; then rm -f "$err"; return 3; fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$raw" | jq -r '.content // empty' | base64 -d > "$docf" 2>/dev/null || return 1
  printf '%s' "$raw" | jq -r '.sha // empty' > "$shaf"
  return 0
}

# put_file <path> <content-file> <sha-or-empty> <message> → stdout: the new blob sha; exit 0/1;
# stderr keeps gh's message (409/422 conflict detection is the caller's).
put_file() {
  local path=$1 content=$2 sha=$3 msg=$4 body
  body=$(jq -n --arg m "$msg" --arg c "$(base64 -w0 "$content")" --arg sha "$sha" --arg b "$(state_branch)" \
    '{message: $m, content: $c, branch: $b} + (if $sha != "" then {sha: $sha} else {} end)')
  printf '%s' "$body" | gh api -X PUT "repos/$REPO/contents/$path" --input - --jq '.content.sha'
}

delete_file() { # <path> <sha> <message>
  local path=$1 sha=$2 msg=$3 body
  body=$(jq -n --arg m "$msg" --arg sha "$sha" --arg b "$(state_branch)" '{message: $m, sha: $sha, branch: $b}')
  printf '%s' "$body" | gh api -X DELETE "repos/$REPO/contents/$path" --input - >/dev/null
}

is_conflict() { # <stderr-file>: a stale-sha PUT (HTTP 409 "does not match", or 422 on a sha)
  grep -qE 'HTTP 409|does not match|HTTP 422.*sha' "$1"
}

# bad_sig_commit <issue>: the last commit that touched the file — for the perimeter comment
bad_sig_commit() {
  gh api "repos/$REPO/commits?path=issues/$1.json&sha=$(state_branch)&per_page=1" --jq '.[0].sha // empty' 2>/dev/null
}

# ── read ─────────────────────────────────────────────────────────────────────────

# read_state <issue> <doc-out> <sha-out>: 0 ok, 3 absent, 6 bad sig, 1 API error
read_state() {
  local issue=$1 docf=$2 shaf=$3 rc
  fetch_file "issues/$issue.json" "$docf" "$shaf"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  jq -e 'type == "object"' "$docf" >/dev/null 2>&1 || { log "state #$issue is not a JSON object"; return 6; }
  if ! verify_doc "$docf"; then
    local c
    c=$(bad_sig_commit "$issue")
    log "state #$issue: signature missing or mismatching (commit ${c:-unknown})"
    return 6
  fi
  return 0
}

cmd_read() {
  need_key
  need_repo
  local issue=${1:-} shafile="" docf shaf rc
  [ -n "$issue" ] || die "read: an issue number is required"
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --sha-file) shafile=$2; shift 2 ;;
      *) die "read: unknown option $1" ;;
    esac
  done
  docf=$(tmpf .json) || die "read: no temp dir"
  shaf=$(tmpf .sha) || die "read: no temp dir"
  read_state "$issue" "$docf" "$shaf"
  rc=$?
  if [ $rc -ne 0 ]; then
    rm -f "$docf" "$shaf"
    case $rc in
      3) log "state #$issue: absent" ;;
      1) die "cannot read state #$issue (non-404) — refusing to guess" ;;
    esac
    exit $rc
  fi
  STATE_SHA=$(cat "$shaf")
  export STATE_SHA
  { printf '%s\n' "$STATE_SHA" >&3; } 2>/dev/null || true
  [ -n "$shafile" ] && printf '%s\n' "$STATE_SHA" > "$shafile"
  [ -n "${STATE_SHA_FILE:-}" ] && printf '%s\n' "$STATE_SHA" > "$STATE_SHA_FILE"
  cat "$docf"
  rm -f "$docf" "$shaf"
  exit 0
}

# ── transitions ──────────────────────────────────────────────────────────────────

# parse_transition_args "$@" → JQ_ARGS[] (the caller's --arg/--argjson/--rawfile, plus
# now/run_id defaults) and MESSAGE
JQ_ARGS=()
MESSAGE=""
parse_transition_args() {
  local have_now=0 have_run=0
  JQ_ARGS=()
  while [ $# -gt 0 ]; do
    case $1 in
      --arg|--argjson|--rawfile|--slurpfile)
        [ $# -ge 3 ] || die "$1 needs a name and a value"
        [ "$2" = now ] && have_now=1
        [ "$2" = run_id ] && have_run=1
        JQ_ARGS+=("$1" "$2" "$3")
        shift 3 ;;
      --message) MESSAGE=$2; shift 2 ;;
      *) die "unknown transition option $1" ;;
    esac
  done
  [ $have_now -eq 1 ] || JQ_ARGS+=(--arg now "$(now)")
  [ $have_run -eq 1 ] || JQ_ARGS+=(--arg run_id "${RUN_ID:-${GITHUB_RUN_ID:-0}}")
}

transition_file() { # <name> → path; exit 1 with the reason on stderr otherwise
  local t=$1
  case $t in
    _*|*/*|*..*|"") log "not a transition name: '$t'"; return 1 ;;
  esac
  [ -f "$TRANSITIONS/$t.jq" ] || { log "unknown transition '$t' (lib/jq/transitions/$t.jq)"; return 1; }
  printf '%s\n' "$TRANSITIONS/$t.jq"
}

# apply_transition <transition-file> <in-doc> <out-doc>: 0 ok, 5 precondition/input error,
# 1 a jq failure (a bug in the transition — the message is on stderr)
apply_transition() {
  local tf=$1 in=$2 outp=$3 err rc msg
  err=$(tmpf .err) || return 1
  if [ "$in" = null ]; then
    jq -n -L "$TRANSITIONS" "${JQ_ARGS[@]}" -f "$tf" > "$outp" 2> "$err"
  else
    jq -L "$TRANSITIONS" "${JQ_ARGS[@]}" -f "$tf" "$in" > "$outp" 2> "$err"
  fi
  rc=$?
  if [ $rc -eq 0 ]; then rm -f "$err"; return 0; fi
  msg=$(sed -n -E 's/^jq: error \(at [^)]*\): //p' "$err" | head -1)
  [ -n "$msg" ] || msg=$(head -c 400 "$err")
  case $msg in
    precondition:*|input:*) log "state: $msg"; rm -f "$err"; return 5 ;;
  esac
  cat "$err" >&2
  rm -f "$err"
  return 1
}

cmd_apply() {
  need_key
  local src=${1:-} t=${2:-} tf in outp rc
  [ -n "$src" ] && [ -n "$t" ] || die "apply: <json-file|-|null> <transition> [--arg …]"
  shift 2
  parse_transition_args "$@"
  tf=$(transition_file "$t") || die "state: cannot apply transition '$t'"
  outp=$(tmpf .json) || die "apply: no temp dir"
  if [ "$src" = null ]; then
    in=null
  else
    in=$(tmpf .json) || die "apply: no temp dir"
    if [ "$src" = "-" ]; then cat > "$in"; else cp "$src" "$in" || die "apply: cannot read $src"; fi
  fi
  apply_transition "$tf" "$in" "$outp"
  rc=$?
  if [ $rc -ne 0 ]; then rm -f "$outp"; [ "$in" != null ] && rm -f "$in"; exit $rc; fi
  cmd_sign < "$outp"
  rm -f "$outp"
  [ "$in" != null ] && rm -f "$in"
  exit 0
}

cmd_create() {
  need_key
  need_repo
  local issue=${1:-} src=${2:-} signed err existing shaf rc
  [ -n "$issue" ] && [ -n "$src" ] || die "create: <issue> <json-file>"
  [ -f "$src" ] || die "create: no such file: $src"
  jq -e --argjson n "$issue" 'type == "object" and .issue == $n' "$src" >/dev/null 2>&1 || die "create: $src is not a state document for issue #$issue"
  signed=$(tmpf .json) || die "create: no temp dir"
  cmd_sign < "$src" > "$signed" || die "create: cannot sign"
  err=$(tmpf .err) || die "create: no temp dir"
  if put_file "issues/$issue.json" "$signed" "" "swarm #$issue create" >/dev/null 2> "$err"; then
    rm -f "$err"
    cat "$signed"
    rm -f "$signed"
    exit 0
  fi
  if is_conflict "$err" || grep -qE 'HTTP 422' "$err"; then
    rm -f "$err"
    log "state #$issue already exists"
    existing=$(tmpf .json) || die "create: no temp dir"
    shaf=$(tmpf .sha) || die "create: no temp dir"
    read_state "$issue" "$existing" "$shaf"
    rc=$?
    [ $rc -eq 0 ] && cat "$existing"
    rm -f "$existing" "$shaf" "$signed"
    [ $rc -eq 6 ] && exit 6
    exit 7
  fi
  cat "$err" >&2
  rm -f "$err" "$signed"
  die "create: PUT of issues/$issue.json failed"
}

cmd_write() {
  need_key
  need_repo
  local issue=${1:-} t=${2:-} tf docf shaf newf signed err rc conflicts=0 sha before after hook seen_seq cur_seq
  [ -n "$issue" ] && [ -n "$t" ] || die "write: <issue> <transition> [--arg k v]…"
  shift 2
  parse_transition_args "$@"
  tf=$(transition_file "$t") || die "state: cannot apply transition '$t'"
  [ -n "$MESSAGE" ] || MESSAGE="swarm #$issue $t"
  docf=$(tmpf .json) || die "write: no temp dir"
  shaf=$(tmpf .sha) || die "write: no temp dir"
  newf=$(tmpf .json) || die "write: no temp dir"
  signed=$(tmpf .json) || die "write: no temp dir"
  err=$(tmpf .err) || die "write: no temp dir"
  cleanup() { rm -f "$docf" "$shaf" "$newf" "$signed" "$err"; }
  seen_seq=-1
  while :; do
    read_state "$issue" "$docf" "$shaf"
    rc=$?
    case $rc in
      0) ;;
      3) cleanup; log "state #$issue: absent"; exit 3 ;;
      6) cleanup; exit 6 ;;
      *) cleanup; die "cannot read state #$issue — refusing to guess" ;;
    esac
    # `seq` only goes up. A re-read after a CAS conflict that comes back with a LOWER
    # counter is not another writer racing us — it is the state branch being rolled
    # back to an older (still validly signed) document underneath us. Never merge onto
    # that: the whole point of the counter is that the signature alone cannot tell an
    # old document from the current one.
    cur_seq=$(jq -r '.seq // 0' "$docf" 2>/dev/null)
    case $cur_seq in ''|*[!0-9]*) cur_seq=0 ;; esac
    if [ "$cur_seq" -lt "$seen_seq" ]; then
      cleanup
      die "state #$issue went backwards (seq $seen_seq → $cur_seq) — the state branch was rewound; nothing written"
    fi
    seen_seq=$cur_seq
    sha=$(cat "$shaf")
    apply_transition "$tf" "$docf" "$newf"
    rc=$?
    if [ $rc -eq 5 ]; then cleanup; exit 5; fi
    [ $rc -eq 0 ] || { cleanup; die "transition $t failed on state #$issue"; }
    # `seq` is excluded from the comparison: state_pre bumps it on every transition, so
    # counting it would make a genuine no-op look like a change and write every time.
    before=$(jq -S -c 'del(.sig, .seq)' "$docf")
    after=$(jq -S -c 'del(.sig, .seq)' "$newf")
    if [ "$before" = "$after" ]; then
      log "state #$issue: $t changed nothing — not written"
      cat "$docf"
      cleanup
      exit 0
    fi
    cmd_sign < "$newf" > "$signed" || { cleanup; die "write: cannot sign"; }
    if [ -n "${SWARM_STATE_RACE_HOOK:-}" ] && [ -n "${SWARM_FAKE_GH:-}" ]; then
      hook=$SWARM_STATE_RACE_HOOK
      ( unset SWARM_STATE_RACE_HOOK; bash -c "$hook" ) >&2 || true
    fi
    if put_file "issues/$issue.json" "$signed" "$sha" "$MESSAGE" >/dev/null 2> "$err"; then
      cat "$signed"
      cleanup
      exit 0
    fi
    if is_conflict "$err"; then
      conflicts=$((conflicts + 1))
      log "state #$issue: CAS conflict $conflicts on $t ($(head -c 160 "$err" | tr '\n' ' ')) — re-reading"
      if [ $conflicts -ge $MAX_ATTEMPTS ]; then
        cleanup
        die "state #$issue: $MAX_ATTEMPTS CAS conflicts on $t — giving up"
      fi
      sleep "${SWARM_RETRY_SLEEP:-1}"
      continue
    fi
    cat "$err" >&2
    cleanup
    die "state #$issue: PUT failed on $t"
  done
  cleanup
  die "state #$issue: $MAX_ATTEMPTS CAS conflicts on $t — giving up"
}

# ── pending artifacts (§9.1) ─────────────────────────────────────────────────────

pending_path() { printf 'issues/%s/pending/%s\n' "$1" "$2"; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

cmd_stage_pending() {
  need_key
  need_repo
  local issue=${1:-} src=${2:-} name=${3:-} sum cur curf shaf rc err
  [ -n "$issue" ] && [ -n "$src" ] || die "stage-pending: <issue> <local-file> [<name>]"
  [ -f "$src" ] || die "stage-pending: no such file: $src"
  [ -n "$name" ] || name=$(basename "$src")
  [[ $name =~ ^([A-Za-z0-9_]|\.[A-Za-z0-9_-])[A-Za-z0-9._-]*(/([A-Za-z0-9_]|\.[A-Za-z0-9_-])[A-Za-z0-9._-]*)*$ ]] || die "stage-pending: '$name' is not a safe artifact path"
  sum=$(sha256_of "$src")
  curf=$(tmpf .cur) || die "stage-pending: no temp dir"
  shaf=$(tmpf .sha) || die "stage-pending: no temp dir"
  cur=""
  fetch_file "$(pending_path "$issue" "$name")" "$curf" "$shaf"
  rc=$?
  case $rc in
    0) cur=$(cat "$shaf") ;;
    3) ;;
    *) rm -f "$curf" "$shaf"; die "stage-pending: cannot read the staging area" ;;
  esac
  rm -f "$curf" "$shaf"
  err=$(tmpf .err) || die "stage-pending: no temp dir"
  if ! put_file "$(pending_path "$issue" "$name")" "$src" "$cur" "swarm #$issue stage $name" >/dev/null 2> "$err"; then
    cat "$err" >&2
    rm -f "$err"
    die "stage-pending: cannot upload $name"
  fi
  rm -f "$err"
  cmd_write "$issue" pending-stage --arg file "$name" --arg sha256 "$sum" >/dev/null || exit $?
  printf '%s %s\n' "$name" "$sum"
  exit 0
}

cmd_copy_pending() {
  need_key
  need_repo
  local issue=${1:-} dir=${2:-} docf shaf rc entries f want got tmp bad=0 n=0
  [ -n "$issue" ] && [ -n "$dir" ] || die "copy-pending: <issue> <dir>"
  docf=$(tmpf .json) || die "copy-pending: no temp dir"
  shaf=$(tmpf .sha) || die "copy-pending: no temp dir"
  read_state "$issue" "$docf" "$shaf"
  rc=$?
  [ $rc -eq 0 ] || { rm -f "$docf" "$shaf"; exit $rc; }
  entries=$(jq -r '.pending_artifacts // [] | .[] | "\(.file)\t\(.sha256)"' "$docf")
  rm -f "$docf" "$shaf"
  tmp=$(tmpf .pending) || die "copy-pending: no temp dir"
  while IFS=$'\t' read -r f want; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    fetch_file "$(pending_path "$issue" "$f")" "$tmp" "$shaf.x"
    rc=$?
    if [ $rc -ne 0 ]; then
      log "copy-pending: $f is recorded but not staged (rc $rc)"
      bad=1
      continue
    fi
    got=$(sha256_of "$tmp")
    if [ "$got" != "$want" ]; then
      log "copy-pending: $f sha256 mismatch — recorded $want, staged $got; not copied"
      bad=1
      continue
    fi
    mkdir -p "$dir/$(dirname "$f")"
    cp "$tmp" "$dir/$f"
    printf '%s\n' "$f"
  done <<< "$entries"
  rm -f "$tmp" "$shaf.x"
  [ $bad -eq 0 ] || exit 8
  log "copy-pending: $n file(s) copied into $dir"
  exit 0
}

cmd_clear_pending() {
  need_key
  need_repo
  local issue=${1:-} name=${2:-} curf shaf rc
  [ -n "$issue" ] && [ -n "$name" ] || die "clear-pending: <issue> <name>"
  curf=$(tmpf .cur) || die "clear-pending: no temp dir"
  shaf=$(tmpf .sha) || die "clear-pending: no temp dir"
  fetch_file "$(pending_path "$issue" "$name")" "$curf" "$shaf"
  rc=$?
  case $rc in
    0) delete_file "$(pending_path "$issue" "$name")" "$(cat "$shaf")" "swarm #$issue landed $name" || log "clear-pending: delete of $name failed (entry cleared anyway)" ;;
    3) log "clear-pending: $name was not staged" ;;
    *) rm -f "$curf" "$shaf"; die "clear-pending: cannot read the staging area" ;;
  esac
  rm -f "$curf" "$shaf"
  cmd_write "$issue" pending-clear --arg file "$name" >/dev/null || exit $?
  exit 0
}

# ── keys, rendering, comments ────────────────────────────────────────────────────

cmd_next_key() {
  local f=${1:-} stage=${2:-} role=${3:-}
  [ -n "$f" ] && [ -n "$stage" ] && [ -n "$role" ] || die "next-key: <json-file> <stage> <role>"
  [ -f "$f" ] || die "next-key: no such file: $f"
  jq -r --arg s "$stage" --arg r "$role" '"\(.issue):\($s):\($r):\((((.stages[$s] // {}).attempts // {})[$r] // 0) + 1)"' "$f"
}

render_args() { # → RENDER_ARGS[] from config/env
  RENDER_ARGS=(--arg at "$(now)")
  local cap="" ad="" sb=""
  if [ -n "${CONFIG_JSON:-}" ] && [ -f "$CONFIG_JSON" ]; then
    cap=$(jq -r '.limits.cost_usd_per_issue // empty' "$CONFIG_JSON" 2>/dev/null)
    ad=$(jq -r '.artifacts_dir // empty' "$CONFIG_JSON" 2>/dev/null)
    sb=$(jq -r '.state_branch // empty' "$CONFIG_JSON" 2>/dev/null)
  fi
  [ -n "$cap" ] && RENDER_ARGS+=(--arg cap "$cap")
  [ -n "$ad" ] && RENDER_ARGS+=(--arg artifacts_dir "$ad")
  RENDER_ARGS+=(--arg state_branch "${sb:-$(state_branch)}")
  [ -n "${SWARM_REF:-}" ] && RENDER_ARGS+=(--arg swarm_ref "$SWARM_REF")
  [ -n "${RUN_URL:-}" ] && RENDER_ARGS+=(--arg run_url "$RUN_URL")
  return 0
}

cmd_render() {
  local f=${1:-} outp="-" tmp
  [ -n "$f" ] || die "render: <json-file> [--out F]"
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --out) outp=$2; shift 2 ;;
      *) die "render: unknown option $1" ;;
    esac
  done
  [ -f "$f" ] || die "render: no such file: $f"
  local -a RENDER_ARGS
  render_args
  tmp=$(tmpf .md) || die "render: no temp dir"
  jq -r "${RENDER_ARGS[@]}" -f "$SWARM_ROOT/lib/jq/render-state.jq" "$f" > "$tmp" || { rm -f "$tmp"; die "render: lib/jq/render-state.jq failed"; }
  if [ "$outp" = "-" ]; then cat "$tmp"; rm -f "$tmp"; else mv -f "$tmp" "$outp"; fi
  exit 0
}

cmd_sync_comment() {
  need_key
  need_repo
  local issue=${1:-} src=${2:-} docf shaf rc body pref existing id
  [ -n "$issue" ] || die "sync-comment: <issue> [<json-file>]"
  docf=$(tmpf .json) || die "sync-comment: no temp dir"
  if [ -n "$src" ]; then
    cp "$src" "$docf" || die "sync-comment: cannot read $src"
  else
    shaf=$(tmpf .sha) || die "sync-comment: no temp dir"
    read_state "$issue" "$docf" "$shaf"
    rc=$?
    rm -f "$shaf"
    [ $rc -eq 0 ] || { rm -f "$docf"; exit $rc; }
  fi
  body=$(tmpf .md) || die "sync-comment: no temp dir"
  local -a RENDER_ARGS
  render_args
  jq -r "${RENDER_ARGS[@]}" -f "$SWARM_ROOT/lib/jq/render-state.jq" "$docf" > "$body" || { rm -f "$docf" "$body"; die "sync-comment: render failed"; }
  pref=$(jq -r '.state_comment_id // empty' "$docf")
  if existing=$(ISSUE=$issue find_comment "$issue" "$(marker_pred state "issue=$issue")" "$pref"); then
    id=$(printf '%s' "$existing" | jq -r .id)
    edit_comment "$id" "$body" || { rm -f "$docf" "$body"; die "sync-comment: edit of $id failed"; }
  else
    id=$(post_comment "$issue" "$body") || { rm -f "$docf" "$body"; die "sync-comment: post failed"; }
    if [ -z "$src" ] && [ "$pref" != "$id" ]; then
      cmd_write "$issue" comment-id --arg target state --arg comment_id "$id" >/dev/null || log "sync-comment: could not record comment $id"
    fi
  fi
  rm -f "$docf" "$body"
  printf '%s\n' "$id"
  exit 0
}

# ── branch, totals, billing, re-signing ──────────────────────────────────────────

cmd_branch_exists() {
  local r=${1:-${REPO:-}}
  [ -n "$r" ] || die "branch-exists: <owner/repo>"
  gh api "repos/$r/git/ref/heads/$(state_branch)" >/dev/null 2>&1
}

cmd_init_branch() {
  local r=${1:-${REPO:-}} branch tree commit err readme
  [ -n "$r" ] || die "init-branch: <owner/repo>"
  branch=$(state_branch)
  if gh api "repos/$r/git/ref/heads/$branch" >/dev/null 2>&1; then
    log "init-branch: $branch exists on $r"
    exit 0
  fi
  readme="# swarm state\n\nOne signed JSON file per issue (\`issues/<N>.json\`) and staged artifacts under \`issues/<N>/pending/\`, written by the dispatcher through the Contents API. Never edit by hand: every file carries an HMAC, and a hand edit blocks the issue on \`blocked:perimeter\`.\n"
  tree=$(jq -n --arg c "$(printf "$readme")" '{tree: [{path: "README.md", mode: "100644", type: "blob", content: $c}]}' \
    | gh api -X POST "repos/$r/git/trees" --input - --jq .sha) || die "init-branch: cannot create the tree"
  [ -n "$tree" ] || die "init-branch: the tree has no sha"
  commit=$(jq -n --arg t "$tree" '{message: "swarm: state branch", tree: $t, parents: []}' \
    | gh api -X POST "repos/$r/git/commits" --input - --jq .sha) || die "init-branch: cannot create the root commit"
  [ -n "$commit" ] || die "init-branch: the commit has no sha"
  err=$(tmpf .err) || die "init-branch: no temp dir"
  if jq -n --arg r "refs/heads/$branch" --arg s "$commit" '{ref: $r, sha: $s}' | gh api -X POST "repos/$r/git/refs" --input - >/dev/null 2> "$err"; then
    rm -f "$err"
    log "init-branch: created $branch on $r at $commit"
    exit 0
  fi
  if grep -qE 'HTTP 422|already exists' "$err"; then
    rm -f "$err"
    log "init-branch: $branch already exists on $r"
    exit 0
  fi
  cat "$err" >&2
  rm -f "$err"
  die "init-branch: cannot create refs/heads/$branch"
}

# list_state_files <repo> → one path per line (issues/<N>.json), empty when none
list_state_files() {
  gh api "repos/$1/contents/issues?ref=$(state_branch)" --jq '.[] | select(.type == "file") | select(.name | test("^[0-9]+\\.json$")) | .path' 2>/dev/null
}

cmd_month_totals() {
  local r=${1:-${REPO:-}} month=${2:-} paths p docf shaf sum n=0
  [ -n "$r" ] || die "month-totals: <owner/repo> [YYYY-MM]"
  [ -n "$month" ] || month=$(now | cut -c1-7)
  REPO=$r
  paths=$(list_state_files "$r")
  docf=$(tmpf .json) || die "month-totals: no temp dir"
  shaf=$(tmpf .sha) || die "month-totals: no temp dir"
  sum=$(tmpf .sum) || die "month-totals: no temp dir"
  : > "$sum"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    fetch_file "$p" "$docf" "$shaf" || continue
    if [ -n "${SWARM_STATE_KEY:-}" ] && ! verify_doc "$docf"; then
      log "month-totals: $p has a bad signature — skipped"
      continue
    fi
    # Attribute per dispatch, not per issue. Taking the issue's LIFETIME totals whenever
    # any of its dates touched the month counted an issue that spans a month boundary in
    # full in both months — and this is the figure the monthly brake (G31) runs on, so it
    # tripped earlier and more often than the real spend warranted. Records folded out of
    # dispatches[] (the 60-record cap) are no longer attributable to a month and are left
    # out; the issue's own totals still carry them.
    #
    # Minutes are clamped at zero per record. A stored negative is always a measurement
    # fault, never a real span, and one poisoned record would otherwise drag the whole
    # month below the brake and keep it unreachable — state files written before the
    # advance.sh zero-date fix carry exactly that.
    jq -c --arg m "$month" '
      select(type == "object")
      | ([(.dispatches // [])[] | select(((.at // "")[0:7]) == $m)]) as $d
      | select((($d | length) > 0) or ((.created_at // "")[0:7] == $m))
      | {issue,
         runner_minutes: ([$d[] | .job_minutes // 0 | if . < 0 then 0 else . end] | add // 0 | floor),
         overhead_minutes: ([$d[] | .overhead_minutes // 0 | if . < 0 then 0 else . end] | add // 0 | floor),
         cost_usd: ([$d[] | .cost_usd // 0] | add // 0)}' "$docf" >> "$sum"
    n=$((n + 1))
  done <<< "$paths"
  jq -s --arg m "$month" '{
      month: $m,
      runner_minutes: ([.[].runner_minutes] | add // 0),
      overhead_minutes: ([.[].overhead_minutes] | add // 0),
      minutes: (([.[].runner_minutes] | add // 0) + ([.[].overhead_minutes] | add // 0)),
      cost_usd: (([.[].cost_usd] | add // 0) * 100 | round / 100),
      issues: [.[].issue] }' "$sum"
  rm -f "$docf" "$shaf" "$sum"
  exit 0
}

cmd_billing_used() {
  local owner=${1:-${OWNER:-}} used
  [ -n "$owner" ] || die "billing-used: <owner>"
  if [ -z "${SWARM_TOKEN:-}" ]; then
    log "billing-used: SWARM_TOKEN unset — the billing endpoint is not readable"
    exit 0
  fi
  used=$(GH_TOKEN="$SWARM_TOKEN" gh api "users/$owner/settings/billing/actions" --jq '.total_minutes_used // empty' 2>/dev/null) || used=""
  case $used in
    ''|*[!0-9.]*) log "billing-used: endpoint refused or answered without total_minutes_used"; exit 0 ;;
  esac
  printf '%s\n' "$used"
  exit 0
}

cmd_resign_all() {
  need_key
  local r=${1:-${REPO:-}} paths p docf shaf signed n=0
  [ -n "$r" ] || die "resign-all: <owner/repo>"
  REPO=$r
  paths=$(list_state_files "$r")
  docf=$(tmpf .json) || die "resign-all: no temp dir"
  shaf=$(tmpf .sha) || die "resign-all: no temp dir"
  signed=$(tmpf .json) || die "resign-all: no temp dir"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    fetch_file "$p" "$docf" "$shaf" || { log "resign-all: cannot read $p"; continue; }
    jq -e 'type == "object"' "$docf" >/dev/null 2>&1 || { log "resign-all: $p is not a JSON object — skipped"; continue; }
    cmd_sign < "$docf" > "$signed" || die "resign-all: cannot sign $p"
    put_file "$p" "$signed" "$(cat "$shaf")" "swarm: re-sign $p" >/dev/null || die "resign-all: PUT of $p failed"
    n=$((n + 1))
    log "resign-all: $p re-signed"
  done <<< "$paths"
  rm -f "$docf" "$shaf" "$signed"
  printf 're-signed %s file(s)\n' "$n"
  exit 0
}

case ${1:-} in
  init-branch) shift; cmd_init_branch "$@" ;;
  branch-exists) shift; cmd_branch_exists "$@" ;;
  read) shift; cmd_read "$@" ;;
  sign) cmd_sign ;;
  verify) cmd_verify ;;
  create) shift; cmd_create "$@" ;;
  write) shift; cmd_write "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  stage-pending) shift; cmd_stage_pending "$@" ;;
  copy-pending) shift; cmd_copy_pending "$@" ;;
  clear-pending) shift; cmd_clear_pending "$@" ;;
  next-key) shift; cmd_next_key "$@" ;;
  render) shift; cmd_render "$@" ;;
  sync-comment) shift; cmd_sync_comment "$@" ;;
  month-totals) shift; cmd_month_totals "$@" ;;
  billing-used) shift; cmd_billing_used "$@" ;;
  resign-all) shift; cmd_resign_all "$@" ;;
  *) sed -n '2,45p' "$0" >&2; exit 1 ;;
esac
