#!/usr/bin/env bash
# gh-shim.sh: the fake `gh` the conformance harness runs every script against.
# common.sh routes `gh` here whenever SWARM_FAKE_GH=<dir> is set. Nothing leaves the
# machine; every answer comes from files under $SWARM_FAKE_GH:
#
#   <METHOD>/<path with '/' → '%2F'[?query]>.json    answers for `gh api` (GET by default);
#                                                    the query-less file is the fallback
#   state/issues-<N>.json                            the state store: served for
#                                                    GET repos/*/contents/issues/<N>.json wrapped
#                                                    as {content: base64, sha: sha1(content)};
#                                                    PUT compares `sha` (409 on mismatch) and
#                                                    writes the decoded content back; DELETE likewise
#   state/pending-<N>-<file>                         repos/*/contents/issues/<N>/pending/<file>
#   cmd/<word1>-<word2>[-<id>].json                  answers for `gh run list`, `gh run view <id>`,
#                                                    `gh pr view`, `gh issue create`, `gh workflow run`…
#   cmd/run-view-<id>-log-failed.txt                 `gh run view <id> --log-failed` (text)
#   artifacts/<id>/                                  copied by `gh run download <id> -D <dir>`
#   calls.log                                        one line per mutating call:
#                                                    `<METHOD> <path>` or `<cmd words> [<id>]`, a tab,
#                                                    then the JSON body / the remaining args
#
# A fixture may fake a failure: an object {"_exit": 1, "_stderr": "gh: HTTP 500: boom",
# "_stdout": …} exits with that code; {"_sequence": [answer, answer, …]} serves the
# answers in turn (the last one repeats) so a retry can be exercised.
# `--jq` is applied with `jq -r` (strings raw, like gh). Absent fixtures: `gh api`
# → "gh: HTTP 404: not found", exit 1; list/view commands → [] / {} exit 0;
# create/run commands → exit 1; other mutations (close, edit, ready, label) → {} exit 0.
# Comments are stateful: POST …/issues/<N>/comments appends to the GET comments
# fixture and returns a fresh id; PATCH …/issues/comments/<id> edits it in place.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

FAKE=${SWARM_FAKE_GH:?SWARM_FAKE_GH must point at the fake-GitHub directory}
mkdir -p "$FAKE/state" "$FAKE/.seq"
LOG="$FAKE/calls.log"

enc() { printf '%s' "$1" | sed 's#/#%2F#g'; }

http_fail() { # <code> <message>
  printf 'gh: HTTP %s: %s\n' "$1" "$2" >&2
  exit 1
}

logcall() { # <first column> <second column>
  printf '%s\t%s\n' "$1" "$2" >> "$LOG"
}

# resolve_fixture <file>: honours _sequence; prints the answer JSON on stdout.
resolve_fixture() {
  local f=$1 key n total
  if jq -e 'type == "object" and has("_sequence")' "$f" >/dev/null 2>&1; then
    key=$(printf '%s' "$f" | sed 's#[^A-Za-z0-9._-]#_#g')
    n=$(cat "$FAKE/.seq/$key" 2>/dev/null || echo 0)
    total=$(jq '._sequence | length' "$f")
    printf '%s' $((n + 1)) > "$FAKE/.seq/$key"
    [ "$n" -ge "$total" ] && n=$((total - 1))
    jq --argjson i "$n" '._sequence[$i]' "$f"
  else
    cat "$f"
  fi
}

# serve <answer-json> [jq-filter]: prints like gh would; handles the _exit convention.
serve() {
  local ans=$1 filter=${2:-} code
  if printf '%s' "$ans" | jq -e 'type == "object" and has("_exit")' >/dev/null 2>&1; then
    code=$(printf '%s' "$ans" | jq -r '._exit')
    printf '%s' "$ans" | jq -r 'if has("_stderr") then ._stderr else empty end' >&2
    printf '%s' "$ans" | jq -r 'if has("_stdout") then (._stdout | if type == "string" then . else tojson end) else empty end'
    exit "$code"
  fi
  if [ -n "$filter" ]; then
    printf '%s' "$ans" | jq -r "$filter"
  elif printf '%s' "$ans" | jq -e 'type == "string"' >/dev/null 2>&1; then
    printf '%s' "$ans" | jq -r .
  else
    printf '%s' "$ans" | jq .
  fi
}

serve_file() { serve "$(resolve_fixture "$1")" "${2:-}"; }

sha1_of() { sha1sum "$1" | cut -d' ' -f1; }

# ── gh api ──────────────────────────────────────────────────────────────────────

api() {
  local method="" input="" filter="" path="" fields
  fields=$(mktemp "$FAKE/.fields.XXXXXX")
  : > "$fields"
  while [ $# -gt 0 ]; do
    case $1 in
      -X|--method) method=$2; shift 2 ;;
      --method=*) method=${1#*=}; shift ;;
      -X?*) method=${1#-X}; shift ;;
      --paginate|--slurp|-i|--include|--silent|--verbose) shift ;;
      -H|--header|--cache|--hostname|-p|--preview|-t|--template) shift 2 ;;
      --input) input=$2; shift 2 ;;
      --input=*) input=${1#*=}; shift ;;
      -f|--raw-field) add_field raw "$2" "$fields"; shift 2 ;;
      -F|--field) add_field typed "$2" "$fields"; shift 2 ;;
      -q|--jq) filter=$2; shift 2 ;;
      --jq=*) filter=${1#*=}; shift ;;
      -*) shift ;;
      *) [ -z "$path" ] && path=$1; shift ;;
    esac
  done
  [ -n "$path" ] || http_fail 400 "gh api needs an endpoint"
  path=${path#https://api.github.com/}
  path=${path#/}
  local query="" bare=$path
  case $path in
    *\?*) query=${path#*\?}; bare=${path%%\?*} ;;
  esac

  local body=""
  if [ -n "$input" ]; then
    if [ "$input" = "-" ]; then body=$(cat); else body=$(cat "$input"); fi
  elif [ -s "$fields" ]; then
    body=$(jq -s 'reduce .[] as $f ({};
      if ($f.k | endswith("[]")) then .[$f.k[:-2]] += [$f.v] else .[$f.k] = $f.v end)' "$fields")
  fi
  rm -f "$fields"
  if [ -z "$method" ]; then
    if [ -n "$body" ]; then method=POST; else method=GET; fi
  fi
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')

  local body_c
  if [ -n "$body" ] && printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    body_c=$(printf '%s' "$body" | jq -c .)
  else
    body_c=$(printf '%s' "$body" | jq -Rs .)
  fi
  [ "$method" = GET ] || logcall "$method $bare" "$body_c"

  # the state store and the pending files
  local sfile sname
  if [[ $bare =~ ^repos/[^/]+/[^/]+/contents/issues/([0-9]+)\.json$ ]]; then
    sfile="$FAKE/state/issues-${BASH_REMATCH[1]}.json"
    sname="issues/${BASH_REMATCH[1]}.json"
    contents_op "$method" "$sfile" "$sname" "$body" "$filter"
    return
  fi
  if [[ $bare =~ ^repos/[^/]+/[^/]+/contents/issues/([0-9]+)/pending/(.+)$ ]]; then
    sfile="$FAKE/state/pending-${BASH_REMATCH[1]}-$(enc "${BASH_REMATCH[2]}")"
    sname="issues/${BASH_REMATCH[1]}/pending/${BASH_REMATCH[2]}"
    contents_op "$method" "$sfile" "$sname" "$body" "$filter"
    return
  fi
  if [ "$method" = GET ] && [[ $bare =~ ^repos/[^/]+/[^/]+/contents/issues$ ]]; then
    list_state_dir "issues" "issues-" ".json" "$filter"
    return
  fi
  if [ "$method" = GET ] && [[ $bare =~ ^repos/[^/]+/[^/]+/contents/issues/([0-9]+)/pending$ ]]; then
    list_state_dir "issues/${BASH_REMATCH[1]}/pending" "pending-${BASH_REMATCH[1]}-" "" "$filter"
    return
  fi

  # explicit fixture first (with the query, then without)
  local f
  for f in "$FAKE/$method/$(enc "$bare")?$query.json" "$FAKE/$method/$(enc "$bare").json"; do
    if [ -f "$f" ]; then
      serve_file "$f" "$filter"
      return
    fi
  done

  # stateful comments
  local n id now_s cfile owner_repo
  if [[ $bare =~ ^repos/([^/]+/[^/]+)/issues/([0-9]+)/comments$ ]] && [ "$method" = POST ]; then
    owner_repo=${BASH_REMATCH[1]}
    n=${BASH_REMATCH[2]}
    cfile="$FAKE/GET/$(enc "repos/$owner_repo/issues/$n/comments").json"
    mkdir -p "$FAKE/GET"
    [ -f "$cfile" ] || printf '[]' > "$cfile"
    id=$(cat "$FAKE/.next-comment-id" 2>/dev/null || echo 1001)
    printf '%s' $((id + 1)) > "$FAKE/.next-comment-id"
    now_s=$(date -u +%FT%TZ)
    local c
    c=$(printf '%s' "$body" | jq -c --argjson id "$id" --arg at "$now_s" --arg n "$n" \
      '{id: $id, body: (.body // ""), user: {login: "github-actions[bot]", type: "Bot"},
        created_at: $at, updated_at: $at, html_url: ("https://github.com/o/r/issues/\($n)#issuecomment-\($id)")}')
    jq --argjson c "$c" '. + [$c]' "$cfile" > "$cfile.tmp" && mv "$cfile.tmp" "$cfile"
    serve "$c" "$filter"
    return
  fi
  if [[ $bare =~ ^repos/[^/]+/[^/]+/issues/comments/([0-9]+)$ ]]; then
    id=${BASH_REMATCH[1]}
    local found=""
    for cfile in "$FAKE"/GET/*%2Fcomments.json; do
      [ -f "$cfile" ] || continue
      if jq -e --argjson id "$id" 'type == "array" and any(.[]; .id == $id)' "$cfile" >/dev/null 2>&1; then
        found=$cfile
        break
      fi
    done
    case $method in
      GET)
        [ -n "$found" ] || http_fail 404 "not found"
        serve "$(jq --argjson id "$id" '.[] | select(.id == $id)' "$found")" "$filter"
        return ;;
      PATCH)
        [ -n "$found" ] || http_fail 404 "not found"
        now_s=$(date -u +%FT%TZ)
        jq --argjson id "$id" --argjson b "$(printf '%s' "$body" | jq -c '.body // ""')" --arg at "$now_s" \
          'map(if .id == $id then .body = $b | .updated_at = $at else . end)' "$found" > "$found.tmp" && mv "$found.tmp" "$found"
        serve "$(jq --argjson id "$id" '.[] | select(.id == $id)' "$found")" "$filter"
        return ;;
      DELETE)
        [ -n "$found" ] || http_fail 404 "not found"
        jq --argjson id "$id" 'map(select(.id != $id))' "$found" > "$found.tmp" && mv "$found.tmp" "$found"
        return ;;
    esac
  fi

  if [ "$method" = GET ]; then
    http_fail 404 "not found (GET $bare)"
  fi
  serve '{}' "$filter"
}

add_field() { # raw|typed k=v <file>
  local kind=$1 kv=$2 file=$3 k v
  k=${kv%%=*}
  v=${kv#*=}
  if [ "$kind" = typed ] && [ "${v#@}" != "$v" ]; then
    if [ "$v" = "@-" ]; then v=$(cat); else v=$(cat "${v#@}"); fi
    jq -n --arg k "$k" --arg v "$v" '{k: $k, v: $v}' >> "$file"
    return
  fi
  if [ "$kind" = typed ]; then
    case $v in
      true|false|null) jq -n --arg k "$k" --argjson v "$v" '{k: $k, v: $v}' >> "$file"; return ;;
    esac
    if [[ $v =~ ^-?[0-9]+$ ]]; then
      jq -n --arg k "$k" --argjson v "$v" '{k: $k, v: $v}' >> "$file"
      return
    fi
  fi
  jq -n --arg k "$k" --arg v "$v" '{k: $k, v: $v}' >> "$file"
}

wrap_content() { # <file> <name>
  local f=$1 name=$2
  jq -n --arg name "$(basename "$name")" --arg path "$name" --arg sha "$(sha1_of "$f")" \
    --arg content "$(base64 -w 60 "$f")" --argjson size "$(wc -c < "$f")" \
    '{name: $name, path: $path, sha: $sha, size: $size, type: "file", encoding: "base64", content: $content}'
}

contents_op() { # <method> <store-file> <gh-name> <body> <filter>
  local method=$1 sfile=$2 sname=$3 body=$4 filter=$5 cur="" want new
  [ -f "$sfile" ] && cur=$(sha1_of "$sfile")
  case $method in
    GET)
      [ -f "$sfile" ] || http_fail 404 "not found ($sname)"
      serve "$(wrap_content "$sfile" "$sname")" "$filter"
      ;;
    PUT)
      [ -n "$body" ] || http_fail 422 "Invalid request. \"content\" wasn't supplied."
      want=$(printf '%s' "$body" | jq -r '.sha // empty')
      if [ -n "$cur" ]; then
        [ -n "$want" ] || http_fail 422 "Invalid request. \"sha\" wasn't supplied. ($sname)"
        [ "$want" = "$cur" ] || http_fail 409 "$sname does not match $want (current $cur)"
      elif [ -n "$want" ]; then
        http_fail 409 "$sname does not match $want (the file is absent)"
      fi
      new=$(mktemp "$FAKE/state/.new.XXXXXX")
      printf '%s' "$body" | jq -r '.content // ""' | base64 -d > "$new" 2>/dev/null \
        || http_fail 422 "content is not valid base64 ($sname)"
      mv "$new" "$sfile"
      serve "$(jq -n --arg sha "$(sha1_of "$sfile")" --arg path "$sname" --arg msg "$(printf '%s' "$body" | jq -r '.message // ""')" \
        '{content: {path: $path, sha: $sha}, commit: {sha: ("c" + $sha[0:39]), message: $msg}}')" "$filter"
      ;;
    DELETE)
      [ -f "$sfile" ] || http_fail 404 "not found ($sname)"
      want=$(printf '%s' "$body" | jq -r '.sha // empty')
      [ -n "$want" ] || http_fail 422 "Invalid request. \"sha\" wasn't supplied. ($sname)"
      [ "$want" = "$cur" ] || http_fail 409 "$sname does not match $want (current $cur)"
      rm -f "$sfile"
      serve '{"content": null, "commit": {"sha": "deleted"}}' "$filter"
      ;;
    *)
      http_fail 405 "$method not allowed on $sname"
      ;;
  esac
}

list_state_dir() { # <dir-name> <prefix> <suffix> <filter>
  local dir=$1 prefix=$2 suffix=$3 filter=$4 f base name
  local items="[]"
  for f in "$FAKE/state/$prefix"*"$suffix"; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    name=${base#"$prefix"}
    if [ -n "$suffix" ]; then name=${name%"$suffix"}$suffix; fi
    name=$(printf '%s' "$name" | sed 's#%2F#/#g')
    items=$(printf '%s' "$items" | jq --arg name "$name" --arg path "$dir/$name" --arg sha "$(sha1_of "$f")" --argjson size "$(wc -c < "$f")" \
      '. + [{name: $name, path: $path, sha: $sha, size: $size, type: "file"}]')
  done
  [ "$items" != "[]" ] || http_fail 404 "not found ($dir)"
  serve "$items" "$filter"
}

# ── gh <command> <subcommand> … ──────────────────────────────────────────────────

cmd() {
  local w1=$1 w2=$2
  shift 2
  local filter="" id="" outdir="." artifact="" logmode="" bodyfile=""
  local -a rest=()
  while [ $# -gt 0 ]; do
    case $1 in
      -q|--jq) filter=$2; rest+=("$1" "$2"); shift 2 ;;
      --jq=*) filter=${1#*=}; rest+=("$1"); shift ;;
      -D|--dir) outdir=$2; rest+=("$1" "$2"); shift 2 ;;
      -n|--name) artifact=$2; rest+=("$1" "$2"); shift 2 ;;
      --log-failed) logmode=log-failed; rest+=("$1"); shift ;;
      --log) logmode=log; rest+=("$1"); shift ;;
      --body-file|-F) bodyfile=$2; rest+=("$1" "$2"); shift 2 ;;
      --json|--workflow|--event|--limit|--repo|-R|--search|--label|-l|--state|-s|--title|-t|--body|-b|--base|-B|--head|-H|--parent|--type|--comment|-c|--color|-d|--description|--add-label|--remove-label|--milestone|-m|--ref|-r|-f|--raw-field|--assignee|-a|--reviewer|--author|-A|--branch|--status|--pattern|--template|--user|--sort|--order|--owner|--visibility|--web|--match|--exclude|--include)
        rest+=("$1" "${2-}"); shift 2 ;;
      -*) rest+=("$1"); shift ;;
      *) [ -z "$id" ] && id=$1; rest+=("$1"); shift ;;
    esac
  done

  local words="$w1 $w2"
  local mutating=0
  case $words in
    "workflow run"|"issue create"|"issue close"|"issue edit"|"issue comment"|"issue reopen"|"label create"|"label delete"|"pr create"|"pr edit"|"pr ready"|"pr merge"|"pr close"|"pr comment"|"pr review"|"secret set"|"release create"|"repo edit")
      mutating=1 ;;
  esac
  if [ $mutating -eq 1 ]; then
    local col1=$words args_json
    [ -n "$id" ] && col1="$words $id"
    args_json=$(printf '%s\n' "${rest[@]}" | jq -R . | jq -s -c .)
    if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then
      args_json=$(printf '%s' "$args_json" | jq -c --rawfile b "$bodyfile" '. + ["body=" + $b]')
    fi
    logcall "$col1" "$args_json"
  fi

  if [ "$words" = "run download" ]; then
    [ -n "$id" ] || { printf 'gh: run id required\n' >&2; exit 1; }
    local src="$FAKE/artifacts/$id"
    if [ -n "$artifact" ] && [ -d "$src/$artifact" ]; then src="$src/$artifact"; fi
    if [ ! -d "$src" ]; then
      printf 'no valid artifacts found to download\n' >&2
      exit 1
    fi
    mkdir -p "$outdir"
    cp -r "$src/." "$outdir/"
    exit 0
  fi

  if [ "$words" = "run view" ] && [ -n "$logmode" ]; then
    local lf="$FAKE/cmd/run-view-$id-$logmode.txt"
    [ -f "$lf" ] && cat "$lf"
    exit 0
  fi

  local f
  for f in "$FAKE/cmd/$w1-$w2${id:+-$id}.json" "$FAKE/cmd/$w1-$w2.json"; do
    if [ -f "$f" ]; then
      serve_file "$f" "$filter"
      exit 0
    fi
  done
  case $w2 in
    list|checks|issues|diff) serve '[]' "$filter" ;;
    view|status) serve '{}' "$filter" ;;
    create|run)
      printf 'gh: no fixture cmd/%s-%s.json — %s needs one to succeed\n' "$w1" "$w2" "$words" >&2
      exit 1 ;;
    *) [ $mutating -eq 1 ] && serve '{}' "$filter" || serve '{}' "$filter" ;;
  esac
  exit 0
}

case ${1:-} in
  api) shift; api "$@" ;;
  --version|version) printf 'gh version 2.98.0 (conformance shim)\n' ;;
  auth) printf 'shim: authenticated\n' ;;
  "") printf 'gh-shim: a command is required\n' >&2; exit 1 ;;
  *)
    [ $# -ge 2 ] || { printf 'gh-shim: unknown invocation: %s\n' "$*" >&2; exit 1; }
    cmd "$@" ;;
esac
