#!/usr/bin/env bash
# pipeline-probe.sh — the pipeline/ conformance checks of spec §16.1.4 over the routing
# data (pipeline.json, pipeline.yml, .claude/agents/). Driven by the cases under
# lib/conformance/cases/pipeline/; each case runs one check, and the negative twins
# feed a mutated pipeline through --mutate to prove the check bites.
#
#   pipeline-probe.sh <check> [--pipeline FILE] [--yaml FILE] [--agents DIR] [--mutate JQ]
#
#   roles-have-files        every role in stages (and `critic`) has <agents>/<role>.md
#   edges-legal             every rework_to (role and critic), ci_on_failure rework, gate
#                           reject_to and verdict_edges entry names a legal role/edge; a
#                           `rework` verdict always has an edge; edge keys name real roles
#                           and verdicts they declare
#   must-differ             every must_differ_from (role and critic) resolves to a role and
#                           the two tiers differ (a critic's tier = critic.tier, else
#                           models.critic_tier_for[role tier])
#   paths-contain           both paths contain triage and retro, name only stages, in the
#                           stage order, without repeats
#   emoji-unique            every role plus critic/dispatch/gate/watchdog has an emoji and
#                           no two are the same
#   on-short-legal          stage/gate/evidence/critic on_short ∈ {run, skip}; role
#                           on_short ∈ {run, skip, when_scan_changed, sensitive_only}
#   json-equals-yaml        jq -S of pipeline.json equals yaml2json of pipeline.yml
#   write-critic-separate   every enabled critic of a write-class role has job: separate,
#                           and no read-class critic asks for a separate job
#   all                     every check above, in that order
#
# Prints `OK: <check> — <detail>` or one `FAIL: <check> — <detail>` per finding; exit 1
# on any finding. Defaults: $SWARM_ROOT/pipeline.json, $SWARM_ROOT/pipeline.yml,
# $SWARM_ROOT/.claude/agents. --mutate applies a jq program to the pipeline before the
# check (negative cases only).
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

check=${1:-}
[ -n "$check" ] || die "pipeline-probe: <check> is required"
shift
pipeline="$SWARM_ROOT/pipeline.json"
yaml="$SWARM_ROOT/pipeline.yml"
agents="$SWARM_ROOT/.claude/agents"
mutate=""
while [ $# -gt 0 ]; do
  case $1 in
    --pipeline) pipeline=$2; shift 2 ;;
    --yaml) yaml=$2; shift 2 ;;
    --agents) agents=$2; shift 2 ;;
    --mutate) mutate=$2; shift 2 ;;
    *) die "pipeline-probe: unknown argument $1" ;;
  esac
done
[ -f "$pipeline" ] || die "pipeline-probe: no pipeline file at $pipeline"

P=$(tmpf .pipeline) || die "pipeline-probe: no temp dir"
if [ -n "$mutate" ]; then
  jq "$mutate" "$pipeline" > "$P" || die "pipeline-probe: --mutate program failed"
else
  jq . "$pipeline" > "$P" || die "pipeline-probe: $pipeline is not JSON"
fi

fails=0
ok() { printf 'OK: %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL: %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

# report <check> <ok-detail> <findings-file> (one finding per line; empty = pass).
# Findings arrive through a file, never a pipe: a pipe would run this in a subshell
# and the failure count would be lost.
report() {
  local c=$1 detail=$2 f=$3 line n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fail "$c" "$line"
    n=$((n + 1))
  done < "$f"
  rm -f "$f"
  [ $n -eq 0 ] && ok "$c" "$detail"
}
findings() { tmpf .findings || die "pipeline-probe: no temp dir"; }

roles_have_files() {
  local r f
  f=$(findings)
  {
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      [ -f "$agents/$r.md" ] || printf 'no role file %s/%s.md\n' "$agents" "$r"
    done < <(jq -r '[.stages[]?.roles[]?.name] + ["critic"] | unique | .[]' "$P")
  } > "$f"
  report roles-have-files "$(jq -r '[.stages[]?.roles[]?.name] + ["critic"] | unique | length' "$P") role files present under $agents" "$f"
}

edges_legal() {
  local f
  f=$(findings)
  jq -r --argjson edges "$(jq -c '.verdict_edges // {}' "$P")" '
    [.stages[]?.roles[]?] as $roles
    | ($roles | map(.name)) as $names
    | ($roles | map(select(.per_lane == true) | .name)) as $per_lane
    | def legal_role: . as $t
        | if $t == "analyst-feedback" then true
          elif ($t | contains(":")) then (($t | split(":")) as $p | ($p | length) == 2 and $p[1] == "<lane>" and ($per_lane | index($p[0]) != null))
          else ($names | index($t) != null) end;
    def legal_edge: . as $e
        | if $e == "next" then true
          elif ($e | test("^(block|park|gate):[a-z-]+$")) then true
          elif $e == "rework:{result.rework_to}" then true
          elif ($e | startswith("rework:")) then ($e | ltrimstr("rework:") | legal_role)
          else false end;
    ( [ .stages[] | .name as $s | .roles[] | select(has("rework_to")) | select(.rework_to | legal_role | not)
        | "role \(.name) (stage \($s)): rework_to \(.rework_to) is not a role" ]
    + [ .stages[] | .name as $s | .roles[] | select((.critic | type) == "object" and (.critic | has("rework_to"))) | select(.critic.rework_to | legal_role | not)
        | "role \(.name) (stage \($s)): critic.rework_to \(.critic.rework_to) is not a role" ]
    + [ .stages[] | .name as $s | .roles[] | select((.ci_on_failure // "") | startswith("rework:")) | select(.ci_on_failure | ltrimstr("rework:") | legal_role | not)
        | "role \(.name) (stage \($s)): ci_on_failure \(.ci_on_failure) names no role" ]
    + [ .stages[] | select((.gate | type) == "object") | select(.gate.reject_to | legal_role | not)
        | "stage \(.name): gate.reject_to \(.gate.reject_to) is not a role" ]
    + [ (.verdict_edges // {}) | to_entries[] | select(.value | legal_edge | not)
        | "verdict_edges[\(.key)] = \(.value) is not a legal edge" ]
    + [ (.verdict_edges // {}) | to_entries[] | (.key | split(".")) as $k
        | select(($k | length) != 2 or ($k[0] != "*" and ($names | index($k[0]) == null)))
        | "verdict_edges key \(.key) names no role" ]
    + [ (.verdict_edges // {}) | to_entries[] | (.key | split(".")) as $k
        | select(($k | length) == 2 and $k[0] != "*" and ($names | index($k[0]) != null))
        | select([ $roles[] | select(.name == $k[0]) | .verdicts[]? ] | index($k[1]) == null)
        | "verdict_edges key \(.key): role \($k[0]) never returns \($k[1])" ]
    + [ .stages[] | .name as $s | .roles[] | select((.verdicts // []) | index("rework") != null)
        | select(has("rework_to") | not) | .name as $r
        | select(($edges["\($r).rework"] // $edges["*.rework"] // "") == "")
        | "role \($r) (stage \($s)): verdict rework has no edge (no rework_to, no verdict_edges entry)" ]
    ) | .[]' "$P" > "$f"
  report edges-legal "every rework_to, ci_on_failure, gate.reject_to and verdict edge names a legal target" "$f"
}

must_differ() {
  local f
  f=$(findings)
  jq -r --argjson ctf "$(jq -c '.models.critic_tier_for // {}' "$P")" '
    [.stages[]?.roles[]?] as $roles
    | def tier_of($n): ([ $roles[] | select(.name == $n) | .tier ] | first);
    ( [ .stages[] | .name as $s | .roles[] | select(has("must_differ_from"))
        | if tier_of(.must_differ_from) == null then "role \(.name) (stage \($s)): must_differ_from \(.must_differ_from) is not a role"
          elif tier_of(.must_differ_from) == .tier then "role \(.name) (stage \($s)): tier \(.tier) equals the tier of \(.must_differ_from)"
          else empty end ]
    + [ .stages[] | .name as $s | .roles[] | select((.critic | type) == "object" and (.critic | has("must_differ_from")))
        | (.critic.tier // $ctf[.tier] // "default") as $ct
        | if tier_of(.critic.must_differ_from) == null then "role \(.name) (stage \($s)): critic.must_differ_from \(.critic.must_differ_from) is not a role"
          elif tier_of(.critic.must_differ_from) == $ct then "role \(.name) (stage \($s)): the critic runs on tier \($ct), the tier of \(.critic.must_differ_from)"
          else empty end ]
    ) | .[]' "$P" > "$f"
  report must-differ "$(jq -r '[.stages[]?.roles[]? | select(has("must_differ_from")), select((.critic | type) == "object" and (.critic | has("must_differ_from")))] | length' "$P") must_differ_from constraint(s) resolve to a different tier" "$f"
}

paths_contain() {
  local f
  f=$(findings)
  jq -r '
    (.stages | map(.name)) as $order
    | (.paths // {}) | to_entries[] | .key as $p | .value as $v
    | ( (if ($v | index("triage")) == null then "path \($p) lacks triage" else empty end),
        (if ($v | index("retro")) == null then "path \($p) lacks retro" else empty end),
        ($v[] | select(. as $s | ($order | index($s)) == null) | "path \($p) names unknown stage \(.)"),
        (if ($v | unique | length) != ($v | length) then "path \($p) repeats a stage" else empty end),
        (if ([ $v[] | . as $s | ($order | index($s)) ] | . == sort) then empty else "path \($p) is not in stage order" end)
      )' "$P" > "$f"
  report paths-contain "paths $(jq -r '.paths | keys | join(", ")' "$P") contain triage and retro in stage order" "$f"
}

emoji_unique() {
  local f
  f=$(findings)
  jq -r '
    (.emoji // {}) as $e
    | ( ([.stages[]?.roles[]?.name] + ["critic", "dispatch", "gate", "watchdog"] | unique | .[] | select(($e[.] // "") == "") | "no emoji for \(.)"),
        ($e | to_entries | group_by(.value) | .[] | select(length > 1) | "emoji \(.[0].value) is shared by \([.[].key] | join(", "))")
      )' "$P" > "$f"
  report emoji-unique "$(jq -r '.emoji | length' "$P") emoji, all distinct" "$f"
}

on_short_legal() {
  local f
  f=$(findings)
  jq -r '
    ( (.stages[] | select((.on_short // "run") | IN("run", "skip") | not) | "stage \(.name): on_short \(.on_short) is not run|skip"),
      (.stages[] | .name as $s | .roles[] | select(has("on_short")) | select(.on_short | IN("run", "skip", "when_scan_changed", "sensitive_only") | not)
        | "role \(.name) (stage \($s)): on_short \(.on_short) is not run|skip|when_scan_changed|sensitive_only"),
      (.stages[] | .name as $s | .roles[] | select((.critic | type) == "object" and (.critic | has("on_short"))) | select(.critic.on_short | IN("run", "skip") | not)
        | "role \(.name) (stage \($s)): critic.on_short \(.critic.on_short) is not run|skip"),
      (.stages[] | select((.gate | type) == "object" and (.gate | has("on_short"))) | select(.gate.on_short | IN("run", "skip") | not)
        | "stage \(.name): gate.on_short \(.gate.on_short) is not run|skip"),
      (.stages[] | select((.evidence_before | type) == "object" and (.evidence_before | has("on_short"))) | select(.evidence_before.on_short | IN("run", "skip") | not)
        | "stage \(.name): evidence_before.on_short \(.evidence_before.on_short) is not run|skip")
    )' "$P" > "$f"
  report on-short-legal "every on_short value is in its vocabulary" "$f"
}

json_equals_yaml() {
  local a b
  [ -f "$yaml" ] || { fail json-equals-yaml "no YAML source at $yaml"; return; }
  a=$(tmpf .a) || die "pipeline-probe: no temp dir"
  b=$(tmpf .b) || die "pipeline-probe: no temp dir"
  if ! yaml2json < "$yaml" | jq -S . > "$a" 2>/dev/null; then
    fail json-equals-yaml "$yaml does not parse (yaml2json)"
    rm -f "$a" "$b"
    return
  fi
  jq -S . "$P" > "$b"
  if diff -q "$a" "$b" >/dev/null; then
    ok json-equals-yaml "pipeline.json is the JSON of pipeline.yml"
  else
    fail json-equals-yaml "pipeline.json differs from pipeline.yml: $(diff "$a" "$b" | grep -E '^[<>]' | head -n 3 | tr '\n' ' ')"
  fi
  rm -f "$a" "$b"
}

write_critic_separate() {
  local f
  f=$(findings)
  jq -r '
    ( (.stages[] | .name as $s | .roles[] | select(.class == "write" and (.critic | type) == "object" and (.critic.enabled // true) == true)
        | select(.critic.job != "separate") | "write-class role \(.name) (stage \($s)) has a critic without job: separate"),
      (.stages[] | .name as $s | .roles[] | select(.class != "write" and (.critic | type) == "object" and .critic.job == "separate")
        | "read-class role \(.name) (stage \($s)) asks for a separate critic job (the read-class critic is a step)")
    )' "$P" > "$f"
  report write-critic-separate "every write-class critic runs in its own job" "$f"
}

case $check in
  roles-have-files) roles_have_files ;;
  edges-legal) edges_legal ;;
  must-differ) must_differ ;;
  paths-contain) paths_contain ;;
  emoji-unique) emoji_unique ;;
  on-short-legal) on_short_legal ;;
  json-equals-yaml) json_equals_yaml ;;
  write-critic-separate) write_critic_separate ;;
  all)
    roles_have_files; edges_legal; must_differ; paths_contain; emoji_unique; on_short_legal; json_equals_yaml; write_critic_separate ;;
  *) rm -f "$P"; die "pipeline-probe: unknown check $check" ;;
esac
rm -f "$P"
[ $fails -eq 0 ] && exit 0
printf '%d finding(s)\n' "$fails"
exit 1
