#!/usr/bin/env bash
# render-routing.sh — the stage table of spec §2, rendered from pipeline.json (spec
# §16.1.4). Prints the block lib/ROUTING.md carries between `<!-- routing-table -->`
# and `<!-- /routing-table -->`, marker lines included, so CI can diff the two:
#
#   lib/conformance/render-routing.sh [pipeline.json] \
#     | diff - <(sed -n '/<!-- routing-table -->/,/<!-- \/routing-table -->/p' lib/ROUTING.md)
#
# Columns: #, Stage / label, Roles in order (`role:<lane>` = one run per lane;
# `evidence <workflow> →` = an evidence workflow fired before the first role), Tier and
# Class per role, Artifacts (plus "sub-issues" / "draft PR" where a role creates them),
# Critic / check (the critic slot with rubric and threshold, "(off)" when disabled,
# "(full only)" when skipped on the short path, ", separate job" for write-class
# critics; the mechanical requires_ci / requires_evidence / requires_scan checks),
# Rework edges (role rework → target ×max, CI red after role → target, critic → target,
# the owner's free reject edge), Gate after, and Short path (the stage's on_short with
# the per-role, evidence, gate and critic exceptions). To change the table, change
# pipeline.yml, regenerate pipeline.json and re-render lib/ROUTING.md — never by hand.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sh" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

PIPELINE=${1:-$SWARM_ROOT/pipeline.json}
[ -f "$PIPELINE" ] || die "render-routing: no pipeline file at $PIPELINE"
jq -e '.stages | type == "array" and length > 0' "$PIPELINE" >/dev/null 2>&1 \
  || die "render-routing: $PIPELINE has no stages"

printf '%s\n' '<!-- routing-table -->'
printf '%s\n' '| # | Stage / label | Roles in order | Tier | Class | Artifacts | Critic / check | Rework edges | Gate after | Short path |'
printf '%s\n' '|---|---|---|---|---|---|---|---|---|---|'
jq -r '
  def bt: "`" + . + "`";
  def join_or_dash(sep): if length == 0 then "—" else join(sep) end;
  def rolename: if .per_lane then (.name + ":<lane>") else .name end;
  .stages | to_entries[] | (.key + 1) as $n | .value as $s
  | ($s.roles | map(rolename | bt) | join(" → ")) as $roles
  | (if ($s.evidence_before | type) == "object" then ("evidence " + ($s.evidence_before.workflow | bt) + " → ") else "" end) as $ev
  | ($s.roles | map(.tier) | join(", ")) as $tier
  | ($s.roles | map(.class) | join(", ")) as $class
  | ([ $s.roles[] | (.artifacts[] | bt), (if .creates_subissues then "sub-issues" else empty end), (if .opens_pr then "draft PR" else empty end) ]
     | join_or_dash(", ")) as $arts
  | ([ $s.roles[]
       | (if (.critic | type) == "object" then
            "critic " + (.critic.rubric | bt) + " ≥ " + (.critic.threshold | tostring)
            + (if .critic.enabled == false then " (off)" else "" end)
            + (if .critic.on_short == "skip" then " (full only)" else "" end)
            + (if .critic.job == "separate" then ", separate job" else "" end)
          else empty end),
         (if .requires_ci then "check: CI " + .requires_ci + " before " + (rolename | bt) else empty end),
         (if .requires_evidence then "check: evidence " + .requires_evidence + " for " + (rolename | bt) else empty end),
         (if .requires_scan then "check: scan " + .requires_scan + " for " + (rolename | bt) else empty end)
     ] | join_or_dash("; ")) as $critic
  | ([ $s.roles[]
       | (if .rework_to then (rolename | bt) + " rework → " + (.rework_to | bt) + (if .rework_max then " ×" + (.rework_max | tostring) else "" end) else empty end),
         (if ((.ci_on_failure // "") | startswith("rework:")) then "CI red after " + (rolename | bt) + " → " + (.ci_on_failure | ltrimstr("rework:") | bt) else empty end),
         (if (.critic | type) == "object" and .critic.rework_to then "critic → " + (.critic.rework_to | bt) else empty end)
     ] + (if ($s.gate | type) == "object" then [ "owner reject → " + ($s.gate.reject_to | bt) + " (free)" ] else [] end)
     | join_or_dash("; ")) as $rework
  | (if ($s.gate | type) == "object" then
        ($s.gate.name | bt)
        + (if $s.gate.kind == "merge" then " = merge by an approver" else "" end)
        + (if $s.gate.on_short == "skip" then " (full only)" else "" end)
     else "none" end) as $gate
  | (if $s.on_short == "skip" then "**skipped**" else
       ([ "runs" ]
        + [ $s.roles[] | select(.on_short) | (rolename | bt) + " " + (if .on_short == "skip" then "skipped" else .on_short end) ]
        + (if (($s.evidence_before | type) == "object" and $s.evidence_before.on_short == "skip") then [ "no " + ($s.evidence_before.workflow | bt) + " evidence" ] else [] end)
        + (if (($s.gate | type) == "object" and $s.gate.on_short == "skip") then [ "no gate" ] else [] end)
        + [ $s.roles[] | select((.critic | type) == "object" and .critic.on_short == "skip" and .critic.enabled != false) | "no critic" ]
       ) | join("; ") end) as $short
  | "| \($n) | \($s.name | bt) / \($s.label | bt) | \($ev)\($roles) | \($tier) | \($class) | \($arts) | \($critic) | \($rework) | \($gate) | \($short) |"
' "$PIPELINE" || die "render-routing: jq failed over $PIPELINE"
printf '%s\n' '<!-- /routing-table -->'
