#!/usr/bin/env bash
# config.sh: the project's `.github/swarm.yml` → `config.json` (§14).
#
#   config.sh load [--out FILE] [--file LOCAL_YML]
#       Fetches CONFIG_PATH (default .github/swarm.yml) from the repository's default
#       branch through the Contents API (or reads LOCAL_YML), converts YAML → JSON,
#       applies lib/schema/swarm-config.defaults.json, validates, adds `config_sha`
#       (the blob sha) and writes the result. Prints the file's path on stdout, and
#       appends CONFIG_JSON=<path> / CONFIG_SHA=<sha> to $GITHUB_ENV when set.
#       Exit 0 = loaded; exit 4 = missing, unparsable or invalid (the reason is on
#       stderr; the caller maps it to G27, blocked:bad-handoff). Warnings for unknown
#       keys are `::warning::` lines.
#   config.sh get <jq-path> [--file CONFIG_JSON]
#       Prints a value from the loaded config ($CONFIG_JSON by default); strings raw.
#   config.sh sha [--file CONFIG_JSON]
#       Prints config_sha.
#
# Limits: a project may lower the swarm's `limits`, never raise them — a value above
# pipeline.json's is a validation error, not a clamp.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

CONFIG_PATH=${CONFIG_PATH:-.github/swarm.yml}
DEFAULTS_FILE="$SWARM_ROOT/lib/schema/swarm-config.defaults.json"
PIPELINE_FILE="$SWARM_ROOT/pipeline.json"

# Used only when lib/schema/swarm-config.defaults.json is absent (an incomplete tree).
embedded_defaults() {
  cat <<'JSON'
{
  "v": 2,
  "approvers": { "default": [], "requirements": [], "architecture": [], "release": [], "confidence": [] },
  "reporter_may_answer": true,
  "require_model_map": false,
  "default_branch": "main",
  "branch_prefix": "claude/issue-",
  "state_branch": "swarm/state",
  "artifacts_dir": "docs/swarm",
  "requirements_doc": "REQS.md",
  "requirement_id_pattern": "^(FR|NFR)-[A-Z]+-[0-9]+$",
  "pin_marker": "it.failing(",
  "test_paths": [],
  "protected_paths": [],
  "gate_manifests": [],
  "gate_scripts": ["test:ci", "test", "lint", "typecheck", "type-check"],
  "delete_merged_branches": true,
  "lanes": {},
  "evidence": { "ci": "CI" },
  "walkthrough_when": [],
  "contract_command": "",
  "sensitive_paths": [],
  "limits": {
    "rework_budget": 5, "runaway_per_hour": 10, "cost_usd_per_issue": 75,
    "runner_minutes_month": 1500, "usd_month": 200, "question_rounds": 2, "critic_rework": 1,
    "pr_lines": 800, "pr_files": 25, "open_prs": 3, "pushes_per_pr_per_day": 10,
    "evidence_fires_per_issue": 2, "ratelimit_backoff_minutes": 180
  },
  "watchdog": { "gate_reminder_days": 3, "queued_refire_minutes": 30, "evidence_timeout_minutes": 120, "running_stall_minutes": 20 },
  "memory": { "path": "" }
}
JSON
}

# Used only when pipeline.json is absent.
embedded_pipeline_limits() {
  cat <<'JSON'
{ "rework_budget": 5, "runaway_per_hour": 10, "cost_usd_per_issue": 75, "runner_minutes_month": 1500,
  "usd_month": 200, "question_rounds": 2, "critic_rework": 1, "pr_lines": 800, "pr_files": 25, "open_prs": 3,
  "pushes_per_pr_per_day": 10, "evidence_fires_per_issue": 2, "ratelimit_backoff_minutes": 180 }
JSON
}

invalid() {
  printf 'config: %s\n' "$*" >&2
  exit 4
}

cmd_load() {
  local outfile="" local_file="" raw sha yml json defaults plimits merged errors warnings
  while [ $# -gt 0 ]; do
    case $1 in
      --out) outfile=$2; shift 2 ;;
      --file) local_file=$2; shift 2 ;;
      *) die "config.sh load: unknown argument $1" ;;
    esac
  done
  [ -n "$outfile" ] || outfile="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swarm-config.json"

  yml=$(tmpf .yml) || die "config: no temp dir"
  if [ -n "$local_file" ]; then
    [ -f "$local_file" ] || invalid "$local_file not found"
    cp "$local_file" "$yml"
    sha=$(git hash-object "$local_file" 2>/dev/null) || sha=""
  else
    require_env REPO
    local branch
    branch=$(gh api "repos/$REPO" --jq .default_branch 2>/dev/null) || branch=""
    [ -n "$branch" ] || branch=${DEFAULT_BRANCH:-main}
    raw=$(gh api "repos/$REPO/contents/$CONFIG_PATH?ref=$branch" 2>/dev/null) \
      || invalid "$CONFIG_PATH not found on $branch of $REPO"
    printf '%s' "$raw" | jq -r '.content // empty' | base64 -d > "$yml" 2>/dev/null \
      || invalid "$CONFIG_PATH: cannot decode the Contents API answer"
    sha=$(printf '%s' "$raw" | jq -r '.sha // empty')
  fi
  [ -s "$yml" ] || invalid "$CONFIG_PATH is empty"

  json=$(yaml2json < "$yml") || invalid "$CONFIG_PATH is not valid YAML"
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || invalid "$CONFIG_PATH must be a mapping at the top level"

  if [ -f "$DEFAULTS_FILE" ]; then defaults=$(cat "$DEFAULTS_FILE"); else defaults=$(embedded_defaults); fi
  if [ -f "$PIPELINE_FILE" ] && jq -e '.limits | type == "object"' "$PIPELINE_FILE" >/dev/null 2>&1; then
    plimits=$(jq -c .limits "$PIPELINE_FILE")
  else
    plimits=$(embedded_pipeline_limits)
  fi

  # defaults * config: objects merge recursively, arrays and scalars are replaced.
  merged=$(jq -n --argjson d "$defaults" --argjson c "$json" --arg sha "$sha" --arg repo "${REPO:-}" '
    ($d * $c)
    | .config_sha = $sha
    | if (.memory.path // "") == "" and $repo != "" then .memory.path = "memory/github.com/\($repo)" else . end
    | .approvers = ((.approvers // {}) | with_entries(.value = (.value // [])))
  ') || invalid "cannot merge defaults"

  warnings=$(jq -r --argjson d "$defaults" --argjson p "$plimits" '
    [ (keys[] | . as $k | select(($d | has($k)) | not) | select(. != "config_sha")),
      ((.limits // {}) | keys[] | . as $k | select(($p | has($k)) | not) | "limits.\($k)") ] | .[]' <<< "$merged")
  if [ -n "$warnings" ]; then
    # stderr: cmd_load's stdout is the config path and nothing else — its caller
    # captures it with $( ). A ::warning:: on stdout ends up inside CONFIG_JSON, and
    # every consumer then reads a path that does not exist.
    while IFS= read -r k; do printf '::warning::config: unknown key "%s" ignored\n' "$k" >&2; done <<< "$warnings"
  fi

  # G29(b) compares the gate scripts and the blocks named in gate_blocks. A project
  # whose test runner is configured inside the manifest itself, rather than in a
  # separate file, and that names no blocks is only half-covered: a role could leave
  # every script alone and still move the gate by changing which tests run or which
  # files count for coverage. The swarm cannot guess that block's name — it depends on
  # the project's stack, which is why it is configuration and not a constant here.
  if jq -e '((.gate_manifests // []) | length) > 0 and ((.gate_blocks // []) | length) == 0' <<< "$merged" >/dev/null 2>&1; then
    printf '::warning::config: gate_manifests is set but gate_blocks is empty — if your test runner is configured inside one of those manifests, name that block in gate_blocks or G29(b) will not see it change\n' >&2
  fi

  errors=$(jq -r --argjson p "$plimits" '
    def err(c; m): if c then [] else [m] end;
    [ err(.v == 2; "v must be 2"),
      err((.lanes | type) == "object" and (.lanes | length) > 0; "lanes: at least one lane is required"),
      ( (.lanes // {}) | to_entries[] | select((.value.paths | type) != "array" or (.value.paths | length) == 0) | "lanes.\(.key).paths must be a non-empty list" ),
      ( (.lanes // {}) | keys[] | select(test("^[A-Za-z0-9][A-Za-z0-9_-]*$") | not) | "lane name \"\(.)\" must match ^[A-Za-z0-9][A-Za-z0-9_-]*$" ),
      err((.evidence.ci // "" | type) == "string" and (.evidence.ci // "") != ""; "evidence.ci must name the CI workflow"),
      err((.default_branch // "") != ""; "default_branch is required"),
      err((.branch_prefix // "") != ""; "branch_prefix is required"),
      err((.state_branch // "") != ""; "state_branch is required"),
      err((.artifacts_dir // "") != ""; "artifacts_dir is required"),
      err((.approvers | type) == "object"; "approvers must be a mapping"),
      ( (.approvers // {}) | to_entries[] | select((.value | type) != "array" or ([.value[] | type] | any(. != "string"))) | "approvers.\(.key) must be a list of logins" ),
      ( (.approvers // {}) | keys[] | select(IN("default","requirements","architecture","release","confidence") | not) | "approvers.\(.) is not a gate" ),
      err((.limits | type) == "object"; "limits must be a mapping"),
      ( (.limits // {}) | to_entries[] | select((.value | type) != "number" or .value < 0) | "limits.\(.key) must be a number ≥ 0" ),
      ( (.limits // {}) | to_entries[] | . as $e | select(($p | has($e.key)) and ($e.value | type) == "number" and $e.value > $p[$e.key]) | "limits.\($e.key)=\($e.value) raises the swarm limit \($p[$e.key]); a project may only lower it" ),
      err((.watchdog | type) == "object"; "watchdog must be a mapping"),
      ( (.watchdog // {}) | to_entries[] | select((.value | type) != "number" or .value < 0) | "watchdog.\(.key) must be a number ≥ 0" ),
      ( ["test_paths","protected_paths","gate_manifests","gate_scripts","walkthrough_when","sensitive_paths"][] as $k | select((.[$k] | type) != "array") | "\($k) must be a list" ),
      ( ["requirements_doc","requirement_id_pattern","pin_marker"][] as $k | select((.[$k] | type) != "string") | "\($k) must be a string" ),
      err((.contract_command | type) == "string" or (.contract_command | type) == "null"; "contract_command must be a string or null"),
      err((.reporter_may_answer | type) == "boolean"; "reporter_may_answer must be true or false"),
      err((.require_model_map | type) == "boolean"; "require_model_map must be true or false"),
      err((.delete_merged_branches | type) == "boolean"; "delete_merged_branches must be true or false")
    ] | flatten | .[]' <<< "$merged") || invalid "the validator failed on $CONFIG_PATH (see above)"
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" | sed 's/^/config: /' >&2
    exit 4
  fi

  mkdir -p "$(dirname "$outfile")"
  printf '%s\n' "$merged" | jq . > "$outfile" || invalid "cannot write $outfile"
  rm -f "$yml"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'CONFIG_JSON=%s\nCONFIG_SHA=%s\n' "$outfile" "$sha" >> "$GITHUB_ENV"
  fi
  printf '%s\n' "$outfile"
}

cmd_get() {
  local path="" file=${CONFIG_JSON:-}
  while [ $# -gt 0 ]; do
    case $1 in
      --file) file=$2; shift 2 ;;
      *) path=$1; shift ;;
    esac
  done
  [ -n "$path" ] || die "config.sh get: a jq path is required"
  [ -n "$file" ] && [ -f "$file" ] || die "config.sh get: CONFIG_JSON is not set or missing"
  case $path in
    .*) ;;
    *) path=".$path" ;;
  esac
  jq -r "$path // empty | if type == \"string\" then . else tojson end" "$file"
}

cmd_sha() {
  local file=${CONFIG_JSON:-}
  [ "${1:-}" = "--file" ] && file=$2
  [ -n "$file" ] && [ -f "$file" ] || die "config.sh sha: CONFIG_JSON is not set or missing"
  jq -r '.config_sha // empty' "$file"
}

case ${1:-} in
  load) shift; cmd_load "$@" ;;
  get) shift; cmd_get "$@" ;;
  sha) shift; cmd_sha "$@" ;;
  *) die "usage: config.sh load [--out FILE] [--file YML] | get <jq-path> | sha" ;;
esac
