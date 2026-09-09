#!/usr/bin/env bash
# validate-result.sh — spec §7.3, V1–V19, over the role's .swarm-run/result.json.
#
#   validate-result.sh [--final] [--authoritative]
#
# Runs twice per role run: in the run job (advisory — the role could have edited the
# file, the transcript or this script; drives the retry step) and, with
# --authoritative, in `advance` from a fresh swarm checkout and a fresh project
# checkout at the pushed head — that verdict is the one recorded. --final marks the
# second in-job pass after the retry step.
#
# Never exits non-zero. Writes .swarm-run/validation.json
# ({ok, mode, errors: [{check, msg}], warnings: [{check, msg}], downgraded}), prints a
# summary, and sets the step output `ok` (true|false).
#
# Environment (every value is optional when derivable from .swarm-run/state.json and
# .swarm-run/config.json):
#   ROLE, LANE, CLASS, STAGE, ISSUE, ATTEMPT   the brief's identity (V1); ROLE may carry :lane
#   EXEC                                       the action's execution file (V4); .gz accepted
#   BRANCH, BASE_SHA, HEAD                     the integration branch, the attempt's base (state.current.base_sha)
#   ARTIFACTS_DIR                              <artifacts_dir> from config
#   OWNER_REPO (or REPO)                       owner/repo for the url rule (V19)
#   STATE_JSON, CONFIG_JSON                    defaults .swarm-run/state.json, .swarm-run/config.json
#   RUN_DIR                                    default .swarm-run
#   VALIDATION_OUT                             default $RUN_DIR/validation.json
# The shape checks are lib/jq/result-check.jq; everything below is a reality check
# against the tree, git, GitHub or the transcript.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

MODE=job
for a in "$@"; do
  case $a in
    --final) MODE=final ;;
    --authoritative) MODE=authoritative ;;
    *) log "validate: unknown option $a (ignored)" ;;
  esac
done

RUN_DIR=${RUN_DIR:-.swarm-run}
RESULT="$RUN_DIR/result.json"
VALIDATION_OUT=${VALIDATION_OUT:-$RUN_DIR/validation.json}
STATE_JSON=${STATE_JSON:-$RUN_DIR/state.json}
CONFIG_JSON=${CONFIG_JSON:-$RUN_DIR/config.json}
PIPELINE_FILE="$SWARM_ROOT/pipeline.json"
[ -f "$PIPELINE_FILE" ] || PIPELINE_FILE="$RUN_DIR/pipeline.json"

# ── collection ──────────────────────────────────────────────────────────────────

ERRS=()
WARNS=()
DOWNGRADED="{}"
err() { ERRS+=("$(jq -cn --arg c "$1" --arg m "$2" '{check: $c, msg: $m}')"); }
warn() { WARNS+=("$(jq -cn --arg c "$1" --arg m "$2" '{check: $c, msg: $m}')"); }

finish() {
  local ok=true errors warnings n
  [ ${#ERRS[@]} -eq 0 ] || ok=false
  errors=$( (IFS=$'\n'; printf '%s\n' "${ERRS[@]:-}") | jq -s 'map(select(. != null and . != ""))')
  warnings=$( (IFS=$'\n'; printf '%s\n' "${WARNS[@]:-}") | jq -s 'map(select(. != null and . != ""))')
  mkdir -p "$(dirname "$VALIDATION_OUT")" 2>/dev/null
  jq -n --argjson ok "$ok" --arg mode "$MODE" --argjson e "$errors" --argjson w "$warnings" --argjson d "$DOWNGRADED" \
    --arg role "${ROLE:-}" --arg at "$(now)" \
    '{ok: $ok, mode: $mode, role: $role, at: $at, errors: $e, warnings: $w, downgraded: $d}' > "$VALIDATION_OUT" \
    || log "validate: cannot write $VALIDATION_OUT"
  n=${#ERRS[@]}
  if [ "$ok" = true ]; then
    printf 'validate (%s): ok — 0 errors, %s warning(s)\n' "$MODE" "${#WARNS[@]}"
  else
    printf 'validate (%s): NOT ok — %s error(s), %s warning(s)\n' "$MODE" "$n" "${#WARNS[@]}"
    printf '%s' "$errors" | jq -r '.[] | "  \(.check): \(.msg)"'
  fi
  if [ ${#WARNS[@]} -gt 0 ]; then
    printf '%s' "$warnings" | jq -r '.[] | "  warning \(.check): \(.msg)"'
  fi
  out ok "$ok"
  exit 0
}

# ── inputs ──────────────────────────────────────────────────────────────────────

sj() { # <jq expr> [file]: raw value or empty from the state/config
  local f=${2:-$STATE_JSON}
  [ -f "$f" ] || return 0
  jq -r "$1 // empty" "$f" 2>/dev/null
}
cj() { sj "$1" "$CONFIG_JSON"; }

ROLE=${ROLE:-$(sj '.current.role')}
BASE_ROLE=${ROLE%%:*}
if [ -z "${LANE:-}" ] && [ "$ROLE" != "$BASE_ROLE" ]; then LANE=${ROLE#*:}; fi
LANE=${LANE:-}
STAGE=${STAGE:-$(sj '.stage')}
ISSUE=${ISSUE:-$(sj '.issue')}
ATTEMPT=${ATTEMPT:-$(sj '.current.attempt')}
BRANCH=${BRANCH:-$(sj '.branch')}
BASE_SHA=${BASE_SHA:-$(sj '.current.base_sha')}
STATE_HEAD=$(sj '.head')
STATE_PR=$(sj '.pr')
ARTIFACTS_DIR=${ARTIFACTS_DIR:-$(cj '.artifacts_dir')}
ARTIFACTS_DIR=${ARTIFACTS_DIR:-docs/swarm}
OWNER_REPO=${OWNER_REPO:-${REPO:-}}
DEFAULT_BRANCH=$(cj '.default_branch')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

role_entry() { # the role's pipeline.json entry (empty when unknown)
  [ -f "$PIPELINE_FILE" ] || return 0
  if jq -e '.role | type == "object"' "$PIPELINE_FILE" >/dev/null 2>&1; then
    jq -c '.role' "$PIPELINE_FILE"
  else
    jq -c --arg r "$BASE_ROLE" '[.stages[]?.roles[]? | select(.name == $r)] | first // empty' "$PIPELINE_FILE"
  fi
}
ROLE_ENTRY=$(role_entry)
if [ -z "${CLASS:-}" ]; then
  CLASS=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -r '.class // empty')
  if [ -z "$CLASS" ]; then
    case $BASE_ROLE in test-writer|dev|release) CLASS="write" ;; *) CLASS="read" ;; esac
  fi
fi

role_in() { # <name…>: is BASE_ROLE one of them
  local n
  for n in "$@"; do [ "$BASE_ROLE" = "$n" ] && return 0; done
  return 1
}

# under_root <root> <relative path>: prints the resolved path when it exists, is
# not a symlink itself and resolves (realpath -e) under the root; else exit 1.
under_root() {
  local root=$1 rel=$2 rabs abs
  rabs=$(realpath -e -- "$root" 2>/dev/null) || return 1
  [ -e "$root/$rel" ] || return 1
  [ ! -L "$root/$rel" ] || return 1
  abs=$(realpath -e -- "$root/$rel" 2>/dev/null) || return 1
  case $abs in
    "$rabs"/*) printf '%s\n' "$abs"; return 0 ;;
  esac
  return 1
}

norm_ws() { tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//'; }

# ── the file itself ─────────────────────────────────────────────────────────────

if [ ! -e "$RESULT" ]; then
  err schema "result.json missing: the role ended its turn without writing $RESULT"
  finish
fi
if [ -L "$RESULT" ] || [ ! -f "$RESULT" ]; then
  err schema "result.json must be a regular file (not a symlink or a directory)"
  finish
fi
size=$(wc -c < "$RESULT" | tr -d ' ')
if [ "$size" -gt 65536 ]; then
  err schema "result.json is $size bytes; the limit is 64 KB"
fi
if ! iconv -f UTF-8 -t UTF-8 < "$RESULT" >/dev/null 2>&1; then
  err schema "result.json is not valid UTF-8"
fi
if ! jq -e . "$RESULT" >/dev/null 2>&1; then
  err schema "result.json is not valid JSON: $(jq . "$RESULT" 2>&1 | head -c 200)"
  finish
fi
[ ${#ERRS[@]} -eq 0 ] || finish

# ── shape (result-check.jq): schema, V1, V10, V11, V12, V13, V15, V16, V19 ─────

shape_args=()
[ -n "$ROLE" ] && shape_args+=(--arg role "$ROLE")
[ -n "$CLASS" ] && shape_args+=(--arg class "$CLASS")
[ -n "$ISSUE" ] && shape_args+=(--arg issue "$ISSUE")
[ -n "$STAGE" ] && shape_args+=(--arg stage "$STAGE")
[ -n "$ATTEMPT" ] && shape_args+=(--arg attempt "$ATTEMPT")
[ -n "$OWNER_REPO" ] && shape_args+=(--arg owner_repo "$OWNER_REPO")
if [ -f "$SWARM_ROOT/lib/jq/result-check.jq" ]; then
  shape=$(jq -c "${shape_args[@]}" -f "$SWARM_ROOT/lib/jq/result-check.jq" "$RESULT" 2>&1) || {
    err schema "result-check.jq failed: $(printf '%s' "$shape" | head -c 300)"
    finish
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ERRS+=("$line")
  done < <(printf '%s' "$shape" | jq -c '.[]')
else
  err schema "lib/jq/result-check.jq is missing from the swarm tree"
  finish
fi

R() { jq -r "$1 // empty" "$RESULT" 2>/dev/null; }
VERDICT=$(R '.verdict')

# ── V2 artifacts ────────────────────────────────────────────────────────────────

ART_ROOT="$RUN_DIR/artifacts"
declared=$(printf '%s' "${ROLE_ENTRY:-{\}}" | jq -c --arg lane "$LANE" --arg attempt "${ATTEMPT:-1}" \
  '(.artifacts // []) | map(gsub("<lane>"; $lane) | gsub("<attempt>"; $attempt))')
if jq -e '.artifacts | type == "array"' "$RESULT" >/dev/null 2>&1; then
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if ! under_root "$ART_ROOT" "$a" >/dev/null; then
      err V2 "artifacts: $a does not resolve to a regular file under $ART_ROOT/ (missing, a symlink, or outside)"
      continue
    fi
    [ -s "$ART_ROOT/$a" ] || err V2 "artifacts: $a is empty"
    case $a in
      */*) warn V2 "artifacts: $a has a directory component; it lands as its basename $(basename "$a")" ;;
    esac
  done < <(jq -r '.artifacts[] | select(type == "string")' "$RESULT")
fi
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if ! jq -e --arg d "$d" '(.artifacts // []) | index($d) != null' "$RESULT" >/dev/null 2>&1; then
    case $VERDICT in
      pass|rework) err V2 "artifacts: the role's declared artifact $d is not delivered" ;;
      *) warn V2 "artifacts: declared artifact $d not delivered (verdict $VERDICT)" ;;
    esac
  fi
done < <(printf '%s' "$declared" | jq -r '.[]')

# ── V3 / V4 / V5 evidence ───────────────────────────────────────────────────────

TRANSCRIPT_CMDS=""
EXEC_PRESENT=0
if [ -n "${EXEC:-}" ] && [ -f "$EXEC" ]; then
  stats=$("$SWARM_LIB/exec-stats.sh" "$EXEC" 2>/dev/null) || stats='{"present":false}'
  if printf '%s' "$stats" | jq -e '.present == true' >/dev/null 2>&1; then
    EXEC_PRESENT=1
    TRANSCRIPT_CMDS=$(printf '%s' "$stats" | jq -r '.bash_commands[]? | @json')
  fi
fi

n_ev=$(jq '(.evidence // []) | length' "$RESULT")
i=0
while [ "$i" -lt "$n_ev" ]; do
  kind=$(R ".evidence[$i].kind")
  case $kind in
    file)
      p=$(R ".evidence[$i].path")
      line=$(R ".evidence[$i].line")
      sym=$(R ".evidence[$i].symbol")
      if [ -z "$p" ] || [ ! -f "$p" ]; then
        err V3 "evidence[$i]: file $p does not exist in the checkout"
      elif [ -n "$sym" ]; then
        if [ -n "$line" ]; then
          from=$((line - 20)); [ $from -lt 1 ] && from=1
          to=$((line + 20))
          if ! sed -n "${from},${to}p" "$p" | grep -qF -- "$sym"; then
            err V3 "evidence[$i]: symbol $sym not found near $p:$line"
          fi
        elif ! grep -qF -- "$sym" "$p"; then
          err V3 "evidence[$i]: symbol $sym not found in $p"
        fi
      fi
      ;;
    command)
      cmd=$(R ".evidence[$i].cmd" | norm_ws)
      if [ $EXEC_PRESENT -eq 0 ]; then
        warn V4 "evidence[$i]: no transcript to check the command against (execution file absent)"
      else
        hit=0
        while IFS= read -r tc; do
          [ -n "$tc" ] || continue
          tcn=$(printf '%s' "$tc" | jq -r . | norm_ws)
          if [ "$tcn" = "$cmd" ] || [ "${tcn#"$cmd"}" != "$tcn" ]; then hit=1; break; fi
        done <<< "$TRANSCRIPT_CMDS"
        if [ $hit -eq 0 ]; then
          if [ "$CLASS" = write ]; then
            warn V4 "evidence[$i]: command not found in the transcript's Bash calls (advisory for the write class): $cmd"
          else
            err V4 "evidence[$i]: command not found in the transcript's Bash calls: $cmd"
          fi
        fi
      fi
      ;;
    artifact)
      p=$(R ".evidence[$i].path")
      p=${p#.swarm-run/}
      p=${p#./}
      if ! under_root "$RUN_DIR/evidence" "${p#evidence/}" >/dev/null; then
        err V5 "evidence[$i]: artifact $p does not resolve to a file under $RUN_DIR/evidence/"
      fi
      ;;
  esac
  i=$((i + 1))
done

# ── V6 refs ─────────────────────────────────────────────────────────────────────

if role_in analyst ux architect test-writer qa release && jq -e '.refs | type == "array" and length > 0' "$RESULT" >/dev/null 2>&1; then
  reqdoc=$(cj '.requirements_doc')
  candidates=()
  [ -n "$reqdoc" ] && [ -f "$reqdoc" ] && candidates+=("$reqdoc")
  [ -f "$ARTIFACTS_DIR/$ISSUE/requirements.md" ] && candidates+=("$ARTIFACTS_DIR/$ISSUE/requirements.md")
  [ -f "$ART_ROOT/requirements.md" ] && candidates+=("$ART_ROOT/requirements.md")
  [ -f "$RUN_DIR/pending/requirements.md" ] && candidates+=("$RUN_DIR/pending/requirements.md")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ ${#candidates[@]} -eq 0 ]; then
      err V6 "refs: $id cannot be checked — neither ${reqdoc:-the requirements doc} nor $ARTIFACTS_DIR/$ISSUE/requirements.md exists"
      continue
    fi
    if ! grep -qF -- "$id" "${candidates[@]}" 2>/dev/null; then
      err V6 "refs: $id is not found in ${candidates[*]}"
    fi
  done < <(jq -r '.refs[] | select(type == "string")' "$RESULT")
fi

# ── V7 write class on pass ──────────────────────────────────────────────────────

RESULT_HEAD=$(R '.head')
DIFF_FILES=""
ADDED_FILES=""
git_ok=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git_ok=1

if [ "$CLASS" = write ] && [ "$VERDICT" = pass ]; then
  if [ $git_ok -eq 0 ]; then
    err V7 "not inside a git work tree; the pushed head cannot be verified"
  elif [ -z "$BRANCH" ]; then
    err V7 "no integration branch is known (state.branch empty)"
  else
    git fetch -q origin "$BRANCH" >/dev/null 2>&1 || true
    origin_head=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || origin_head=""
    if [ -z "$origin_head" ]; then
      err V7 "origin/$BRANCH cannot be resolved — nothing was pushed, or the branch is unreachable"
    elif [ "$RESULT_HEAD" != "$origin_head" ]; then
      err V7 "head ${RESULT_HEAD:-(unset)} is not origin/$BRANCH ($origin_head)"
    else
      if [ -z "$BASE_SHA" ]; then
        err V7 "the attempt's base sha is unknown (state.current.base_sha empty)"
      elif ! git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
        err V7 "base sha $BASE_SHA is not a commit in this checkout"
      elif ! git merge-base --is-ancestor "$BASE_SHA" "$origin_head" 2>/dev/null; then
        err V7 "history rewritten: base $BASE_SHA is no longer an ancestor of $origin_head"
      else
        DIFF_FILES=$(git diff --name-only "$BASE_SHA...$origin_head" 2>/dev/null | LC_ALL=C sort -u)
        ADDED_FILES=$(git diff --name-only --diff-filter=A "$BASE_SHA...$origin_head" 2>/dev/null | LC_ALL=C sort -u)
        touches=$(jq -r '(.touches // [])[] | select(type == "string")' "$RESULT" | LC_ALL=C sort -u)
        if [ "$touches" != "$DIFF_FILES" ]; then
          only_diff=$(comm -23 <(printf '%s\n' "$DIFF_FILES" | sed '/^$/d') <(printf '%s\n' "$touches" | sed '/^$/d') | tr '\n' ' ')
          only_touch=$(comm -13 <(printf '%s\n' "$DIFF_FILES" | sed '/^$/d') <(printf '%s\n' "$touches" | sed '/^$/d') | tr '\n' ' ')
          err V7 "touches does not equal git diff --name-only $BASE_SHA...$origin_head (changed but not listed: ${only_diff:-none}; listed but unchanged: ${only_touch:-none})"
        fi
        while IFS= read -r c; do
          [ -n "$c" ] || continue
          if ! git show -s --format=%B "$c" | grep -qE "^Swarm-Issue: #${ISSUE}[[:space:]]*$"; then
            err V7 "commit ${c:0:12} lacks the trailer Swarm-Issue: #$ISSUE"
          fi
        done < <(git rev-list "$BASE_SHA..$origin_head" 2>/dev/null)
      fi
    fi
  fi
fi

# ── V8 test-writer / V9 dev ─────────────────────────────────────────────────────

mapfile -t TEST_PATHS < <(cj '.test_paths[]')
PIN=$(cj '.pin_marker')

if role_in test-writer && [ "$VERDICT" = pass ]; then
  if [ -n "$DIFF_FILES" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ${#TEST_PATHS[@]} -eq 0 ] || ! matches_glob "$f" "${TEST_PATHS[@]}"; then
        err V8 "test-writer touched $f, which is outside config.test_paths"
      fi
    done <<< "$DIFF_FILES"
    newtest=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ${#TEST_PATHS[@]} -gt 0 ] && matches_glob "$f" "${TEST_PATHS[@]}"; then newtest=1; fi
    done <<< "$ADDED_FILES"
    [ $newtest -eq 1 ] || err V8 "test-writer added no new test file under config.test_paths"
    if [ -n "$PIN" ]; then
      if ! git diff "$BASE_SHA...$RESULT_HEAD" 2>/dev/null | grep '^+' | grep -qF -- "$PIN"; then
        err V8 "no occurrence of the pin marker $PIN was added"
      fi
    fi
  fi
  if [ -n "$BRANCH" ]; then
    prs=$(gh pr list -R "$OWNER_REPO" --head "$BRANCH" --state open --json number,isDraft,baseRefName 2>/dev/null) || prs="[]"
    if ! printf '%s' "$prs" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
      err V8 "no open pull request exists for $BRANCH"
    else
      prbase=$(printf '%s' "$prs" | jq -r '.[0].baseRefName // empty')
      [ "$prbase" = "$DEFAULT_BRANCH" ] || err V8 "the pull request's base is ${prbase:-unknown}, not $DEFAULT_BRANCH"
      printf '%s' "$prs" | jq -e '.[0].isDraft == true' >/dev/null 2>&1 || warn V8 "the pull request is not a draft"
    fi
  fi
fi

pin_count() { # <rev>: occurrences of the pin marker in the tree at rev
  [ -n "$PIN" ] || { echo 0; return; }
  git grep -F -c -- "$PIN" "$1" 2>/dev/null | awk -F: '{ s += $NF } END { print s + 0 }'
}

if role_in dev && [ "$VERDICT" = pass ] && [ -n "$DIFF_FILES" ] && [ -n "$BASE_SHA" ] && [ -n "$RESULT_HEAD" ]; then
  before=$(pin_count "$BASE_SHA")
  after=$(pin_count "$RESULT_HEAD")
  newtest=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ${#TEST_PATHS[@]} -gt 0 ] && matches_glob "$f" "${TEST_PATHS[@]}"; then newtest=1; fi
  done <<< "$ADDED_FILES"
  if [ "$before" -eq 0 ] && [ -n "$PIN" ]; then
    warn V9 "no pinned test at the base ($BASE_SHA); nothing to flip"
  elif [ "$after" -ge "$before" ] && [ $newtest -eq 0 ]; then
    err V9 "the pin-marker count did not decrease ($before → $after) and no new test file appeared"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $(basename "$f") in
      package-lock.json|yarn.lock|pnpm-lock.yaml|npm-shrinkwrap.json|Gemfile.lock|Cargo.lock|poetry.lock|go.sum|composer.lock|Podfile.lock)
        jq -e --arg f "$f" '(.touches // []) | index($f) != null' "$RESULT" >/dev/null 2>&1 \
          || err V9 "lockfile $f changed but is not listed in touches" ;;
    esac
  done <<< "$DIFF_FILES"
fi

# ── V10 rework target ───────────────────────────────────────────────────────────

lanes_known() { # the issue's lanes (state), else the configured ones
  local l
  l=$(sj '.lanes | select(type == "array" and length > 0) | .[]')
  [ -n "$l" ] || l=$(cj '.lanes | keys[]')
  printf '%s\n' "$l"
}

if [ "$VERDICT" = rework ]; then
  target=$(R '.rework_to')
  case $BASE_ROLE in
    a11y) [ -z "$target" ] || [ "$target" = ux ] || err V10 "a11y rework goes to ux, not $target" ;;
    threat-model) [ -z "$target" ] || [ "$target" = architect ] || err V10 "threat-model rework goes to architect, not $target" ;;
    code-review|qa|security|compliance)
      case $target in
        dev:*)
          lane=${target#dev:}
          lanes_known | grep -qxF -- "$lane" || err V10 "rework_to names lane $lane, which is not one of the issue's lanes ($(lanes_known | tr '\n' ' '))"
          ;;
        *) err V10 "rework_to must be dev:<lane> for $BASE_ROLE (got ${target:-nothing})" ;;
      esac
      ;;
  esac
fi

# ── V11 question rounds ─────────────────────────────────────────────────────────

if [ "$VERDICT" = question ]; then
  rounds=$(sj '.questions.rounds'); rounds=${rounds:-0}
  max=$(sj '.questions.max')
  [ -n "$max" ] || max=$(cj '.limits.question_rounds')
  max=${max:-2}
  if [ "$rounds" -ge "$max" ]; then
    err V11 "question rounds exhausted ($rounds of $max): proceed on stated assumptions instead"
  fi
fi

# ── V12 sub-issues ──────────────────────────────────────────────────────────────

if role_in planner && jq -e '.subissues | type == "array"' "$RESULT" >/dev/null 2>&1; then
  mapfile -t CFG_LANES < <(cj '.lanes | keys[]')
  n_si=$(jq '.subissues | length' "$RESULT")
  i=0
  while [ "$i" -lt "$n_si" ]; do
    lane=$(R ".subissues[$i].lane")
    bf=$(R ".subissues[$i].body_file")
    if ! printf '%s\n' "${CFG_LANES[@]}" | grep -qxF -- "$lane"; then
      err V12 "subissues[$i]: lane $lane is not configured (lanes: ${CFG_LANES[*]})"
    fi
    bf=${bf#.swarm-run/}
    bf=${bf#artifacts/}
    under_root "$ART_ROOT" "$bf" >/dev/null || err V12 "subissues[$i]: body_file does not resolve to a file under $ART_ROOT/"
    i=$((i + 1))
  done
fi

# ── V13 memory entries ──────────────────────────────────────────────────────────

if jq -e '.memory | type == "array" and length > 0' "$RESULT" >/dev/null 2>&1; then
  mem_rel=$(cj '.memory.path')
  [ -n "$mem_rel" ] || mem_rel="memory/github.com/$OWNER_REPO"
  MEM_ROOT="$SWARM_ROOT/$mem_rel"
  n_m=$(jq '.memory | length' "$RESULT")
  i=0
  while [ "$i" -lt "$n_m" ]; do
    mp=$(R ".memory[$i].path")
    cf=$(R ".memory[$i].content_file")
    kind=$(R ".memory[$i].kind")
    if [ -n "$mp" ]; then
      if [ -L "$MEM_ROOT/$mp" ]; then
        err V13 "memory[$i]: $mp is a symlink in the memory folder"
      elif [ -e "$MEM_ROOT/$mp" ]; then
        case $mp in
          "postmortems/$ISSUE.md"|"runs/$ISSUE.json") ;;
          *) err V13 "memory[$i]: $mp already exists — a proposal never overwrites or appends to an existing file" ;;
        esac
      fi
    fi
    cf=${cf#.swarm-run/}
    cf=${cf#artifacts/}
    if ! cabs=$(under_root "$ART_ROOT" "$cf"); then
      err V13 "memory[$i]: content_file does not resolve to a file under $ART_ROOT/"
    else
      case $kind in
        runs)
          jq -e . "$cabs" >/dev/null 2>&1 || err V13 "memory[$i]: $mp must be JSON" ;;
        *)
          fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$cabs")
          if [ -z "$fm" ]; then
            err V13 "memory[$i]: $mp has no frontmatter (name, description, metadata.type)"
          else
            for key in name description; do
              printf '%s\n' "$fm" | grep -qE "^$key:[[:space:]]*[^[:space:]]" || err V13 "memory[$i]: frontmatter lacks $key"
            done
            printf '%s\n' "$fm" | grep -qE '^(metadata:.*type:|[[:space:]]+type:)[[:space:]]*[a-z]' || err V13 "memory[$i]: frontmatter lacks metadata.type"
          fi
          if grep -qF -- '<!--' "$cabs"; then err V13 "memory[$i]: content contains <!--"; fi
          if grep -qE -- '@[A-Za-z0-9-]+' "$cabs"; then err V13 "memory[$i]: content contains an @handle"; fi
          # a shell command line (prompt-style or a bare tool invocation) is allowed
          # only inside a fenced block that carries `# verified against <path:line>`
          bad=$(awk '
            /^```/ { if (infence) { if (!verified && cmds) bad++; infence = 0; verified = 0; cmds = 0 } else { infence = 1 } next }
            infence { if ($0 ~ /# verified against [^ ]+:[0-9]+/) verified = 1; if ($0 ~ /^[[:space:]]*(\$ |(npm|npx|node|git|gh|bash|sh|curl|wget|make|yarn|pnpm|docker|rm|mv|cp|cd|sudo|chmod|python3?) )/) cmds++; next }
            /^[[:space:]]*(\$ |(npm|npx|node|git|gh|bash|sh|curl|wget|make|yarn|pnpm|docker|rm|mv|cp|cd|sudo|chmod|python3?) )/ { bad++ }
            END { print bad + 0 }' "$cabs")
          [ "$bad" -eq 0 ] || err V13 "memory[$i]: $bad shell command line(s) outside a fenced block carrying '# verified against <path:line>'"
          ;;
      esac
    fi
    i=$((i + 1))
  done
fi

# ── V14 release ─────────────────────────────────────────────────────────────────

if role_in release && [ "$VERDICT" = pass ]; then
  if [ -z "$STATE_PR" ] || [ "$STATE_PR" = null ]; then
    err V14 "no pull request is recorded in state (state.pr)"
  else
    pr=$(gh pr view -R "$OWNER_REPO" "$STATE_PR" --json isDraft,baseRefName,headRefOid,body,files 2>/dev/null) || pr=""
    if ! printf '%s' "$pr" | jq -e 'type == "object" and has("baseRefName")' >/dev/null 2>&1; then
      err V14 "pull request #$STATE_PR cannot be read"
    else
      printf '%s' "$pr" | jq -e '.isDraft == false' >/dev/null 2>&1 || err V14 "pull request #$STATE_PR is still a draft"
      prbase=$(printf '%s' "$pr" | jq -r '.baseRefName // empty')
      [ "$prbase" = "$DEFAULT_BRANCH" ] || err V14 "pull request #$STATE_PR targets ${prbase:-unknown}, not $DEFAULT_BRANCH"
      prhead=$(printf '%s' "$pr" | jq -r '.headRefOid // empty')
      want_head=${RESULT_HEAD:-$STATE_HEAD}
      [ -n "$want_head" ] && [ "$prhead" = "$want_head" ] || err V14 "pull request head ${prhead:-unknown} is not the pushed head ${want_head:-unknown}"
      body=$(printf '%s' "$pr" | jq -r '.body // ""')
      printf '%s\n' "$body" | grep -qE "^Swarm-Issue: #${ISSUE}[[:space:]]*$" || err V14 "pull request body lacks the trailer Swarm-Issue: #$ISSUE"
      printf '%s\n' "$body" | grep -qE "(^|[^A-Za-z0-9])Closes #${ISSUE}([^0-9]|$)" || err V14 "pull request body lacks Closes #$ISSUE"
    fi
  fi
  npend=$(sj '.pending_artifacts | length'); npend=${npend:-0}
  if [ "$npend" -gt 0 ]; then
    err V14 "$npend staged artifact(s) have not landed on the branch: $(sj '.pending_artifacts[].file' | tr '\n' ' ')"
  fi
  check_head=${RESULT_HEAD:-$STATE_HEAD}
  if [ $git_ok -eq 1 ] && [ -n "$check_head" ] && [ -f "$PIPELINE_FILE" ] && [ -f "$STATE_JSON" ]; then
    # every artifact a finished pass recorded (declared by its role in pipeline.json,
    # lane and attempt substituted per record; retro's go to memory) must be on head
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      git cat-file -e "$check_head:$ARTIFACTS_DIR/$ISSUE/$f" 2>/dev/null \
        || err V14 "recorded artifact $ARTIFACTS_DIR/$ISSUE/$f is missing on head ${check_head:0:12}"
    done < <(jq -r --slurpfile p "$PIPELINE_FILE" '
      ($p[0] | if has("stages") then [.stages[].roles[]] else [.role] end) as $roles
      | [ (.dispatches // [])[] | select(.status == "finished" and .verdict == "pass")
          | (.role | tostring | split(":")) as $rl | ((.attempt // 1) | tostring) as $at
          | ($roles[] | select(.name == $rl[0]) | .artifacts // [])[]
          | select(. != "postmortem.md")
          | gsub("<lane>"; ($rl[1] // "")) | gsub("<attempt>"; $at) ]
      | unique[]' "$STATE_JSON" 2>/dev/null)
  fi
fi

# ── V15 triage ──────────────────────────────────────────────────────────────────

if role_in triage; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$d" = "$ISSUE" ]; then
      err V15 "duplicates names the issue itself"
    elif ! doc=$(gh api "repos/$OWNER_REPO/issues/$d" 2>/dev/null); then
      err V15 "duplicates: #$d does not exist in $OWNER_REPO"
    elif printf '%s' "$doc" | jq -e 'has("pull_request")' >/dev/null 2>&1; then
      err V15 "duplicates: #$d is a pull request, not an issue"
    fi
  done < <(jq -r '(.duplicates // [])[] | tostring' "$RESULT")
  if [ "$(R '.triage.path')" = short ]; then
    tsize=$(R '.triage.size'); ttype=$(R '.triage.type'); tarea=$(R '.triage.area')
    mapfile -t CFG_LANES < <(cj '.lanes | keys[]')
    onelane=0
    printf '%s\n' "${CFG_LANES[@]}" | grep -qxF -- "$tarea" && onelane=1
    if [ "$tsize" != S ] || { [ "$ttype" != bug ] && [ "$ttype" != chore ]; } || [ $onelane -eq 0 ]; then
      warn V15 "path short requires size S, type bug|chore and a single lane (got $tsize/$ttype/$tarea) — downgraded to full"
      DOWNGRADED=$(printf '%s' "$DOWNGRADED" | jq -c '. + {"triage.path": "full"}')
    fi
  fi
fi

# ── V17 not_covered carries every manifest reason ───────────────────────────────

if role_in qa security compliance release; then
  if [ -d "$RUN_DIR/evidence" ]; then
    while IFS= read -r mf; do
      [ -n "$mf" ] || continue
      wf=$(basename "$(dirname "$mf")")
      while IFS= read -r reason; do
        [ -n "$reason" ] || continue
        if ! jq -e --arg r "$reason" '(.not_covered // []) | any(type == "string" and contains($r))' "$RESULT" >/dev/null 2>&1; then
          err V17 "not_covered lacks the $wf manifest reason: $reason"
        fi
      done < <(jq -r '(.sections // {}) | to_entries[] | select(.value.ran == false) | .value.reason // empty' "$mf" 2>/dev/null)
    done < <(find "$RUN_DIR/evidence" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | sort)
  else
    warn V17 "no evidence directory under $RUN_DIR; manifest reasons not checked"
  fi
fi

# ── V18 read class left the tree and the branch alone ───────────────────────────

if [ "$CLASS" = read ] && [ $git_ok -eq 1 ]; then
  mapfile -t RESTORE < <(jq -r '.restore_from_base[]?' "$PIPELINE_FILE" 2>/dev/null)
  dirty=$(git status --porcelain --untracked-files=all 2>/dev/null | awk '{ print $NF }' | while IFS= read -r f; do
    f=${f#\"}; f=${f%\"}
    case $f in .swarm-run/*|.swarm/*|.swarm-run|.swarm) continue ;; esac
    skip=0
    for r in "${RESTORE[@]}"; do
      [ -n "$r" ] || continue
      if [ "$f" = "$r" ] || [ "${f#"$r"/}" != "$f" ]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] || printf '%s\n' "$f"
  done)
  [ -z "$dirty" ] || err V18 "a read-class role left the tree dirty outside .swarm-run/: $(printf '%s' "$dirty" | tr '\n' ' ')"
  if [ -n "$BRANCH" ] && [ -n "$BASE_SHA" ]; then
    git fetch -q origin "$BRANCH" >/dev/null 2>&1 || true
    origin_head=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || origin_head=""
    if [ -z "$origin_head" ]; then
      err V18 "origin/$BRANCH cannot be resolved; the branch head since the claim is unknown"
    elif [ "$origin_head" != "$BASE_SHA" ]; then
      err V18 "origin/$BRANCH moved during a read-class run ($BASE_SHA → $origin_head)"
    fi
  fi
fi

finish
