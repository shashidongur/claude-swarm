#!/usr/bin/env bash
# portability.sh — nothing portable names a project, lane, framework, platform, tool
# or issue number (spec §1.3, §16.1.4). Two passes over the portable paths
# (.claude/agents/, lib/, PLAYBOOK.md, pipeline.yml, pipeline.json, templates/;
# lib/conformance/fixtures/** and memory/** are exempt):
#
#   1. the fixed grep of the spec (§1.3, implementer rule 3): the project's name, its
#      typecheck target, database, UI framework, infrastructure kit, device tools,
#      scanners, test runners and `#<two or more digits>`; the pattern is assembled
#      from fragments below so this file never contains the words itself.
#   2. for every lane key, evidence workflow name and requirement-id prefix found in
#      lib/conformance/fixtures/config/*.json, the same grep (whole words for names;
#      `<PREFIX>-` case-sensitive for requirement prefixes) — lane and workflow names
#      exist only in project config, memory and fixtures. Skipped, because portable
#      files may legitimately say them: the spec's example lanes `api`/`app`, names
#      of ≤ 2 characters, pipeline stage/role names, and the generic words `ci`,
#      `walkthrough` ("the device walkthrough"), `security`, `test`.
#
# Prints every offending file with the pattern that hit; exit 1 when any hit.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sh" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

cd "$SWARM_ROOT" || die "cannot cd to $SWARM_ROOT"

paths=()
for p in .claude/agents lib PLAYBOOK.md pipeline.yml pipeline.json templates; do
  [ -e "$p" ] && paths+=("$p")
done
[ ${#paths[@]} -gt 0 ] || { echo "portability: nothing to check"; exit 0; }

FIXED='meipa''dam|tsconfig\.che''ck|pgl''ite|react-''native|c''dk|maes''tro|gra''dle|andr''oid|semg''rep|z''ap|je''st|super''test|gitl''eaks|#[0-9]{2,}'
hits=0

report() { # <label> <files…>
  local label=$1 f
  shift
  for f in "$@"; do
    [ -n "$f" ] || continue
    printf '  %s  ←  %s\n' "$f" "$label"
    hits=$((hits + 1))
  done
}

mapfile -t found < <(grep -rilE --exclude-dir=fixtures --exclude-dir=memory -- "$FIXED" "${paths[@]}" 2>/dev/null)
report "fixed pattern" "${found[@]}"

# names from the sample project configs
skip_words="api app ci walkthrough security test"
if [ -f pipeline.json ]; then
  skip_words="$skip_words $(jq -r '[.stages[]? | .name, (.roles[]?.name)] | unique | .[]' pipeline.json 2>/dev/null | tr '\n' ' ')"
fi
is_skipped() {
  local w=$1 s
  [ ${#w} -le 2 ] && return 0
  for s in $skip_words; do [ "$s" = "$w" ] && return 0; done
  return 1
}

names=()
prefixes=()
for cfg in lib/conformance/fixtures/config/*.json; do
  [ -f "$cfg" ] || continue
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    is_skipped "$n" || names+=("$n")
  done < <(jq -r '[(.lanes // {} | keys[]), (.evidence // {} | .[]?)] | .[] | select(type == "string")' "$cfg" 2>/dev/null)
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # "^(FR|NFR)-…" or "^REQ-…" → FR NFR / REQ
    pat=${pat#^}
    pat=${pat%%-*}
    pat=${pat#(}
    pat=${pat%)}
    for alt in ${pat//|/ }; do
      [[ $alt =~ ^[A-Z][A-Z0-9]+$ ]] && prefixes+=("$alt")
    done
  done < <(jq -r '.requirement_id_pattern // empty' "$cfg" 2>/dev/null)
done

mapfile -t names < <(printf '%s\n' "${names[@]}" | sort -u | grep -v '^$')
mapfile -t prefixes < <(printf '%s\n' "${prefixes[@]}" | sort -u | grep -v '^$')

for n in "${names[@]}"; do
  mapfile -t found < <(grep -rilwE --exclude-dir=fixtures --exclude-dir=memory -- "$n" "${paths[@]}" 2>/dev/null)
  report "project name \"$n\" (lane/workflow from a fixture config)" "${found[@]}"
done
for pre in "${prefixes[@]}"; do
  mapfile -t found < <(grep -rlE --exclude-dir=fixtures --exclude-dir=memory -- "(^|[^A-Za-z])${pre}-[A-Z0-9]" "${paths[@]}" 2>/dev/null)
  report "requirement-id prefix \"${pre}-\" (from a fixture config)" "${found[@]}"
done

if [ $hits -eq 0 ]; then
  echo "portability: clean (${#paths[@]} paths; ${#names[@]} project names, ${#prefixes[@]} requirement prefixes checked)"
  exit 0
fi
echo "portability: $hits hit(s) — project, lane, framework, platform, tool and issue-number names belong in .github/swarm.yml, memory or fixtures"
exit 1
