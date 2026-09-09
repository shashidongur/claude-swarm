#!/usr/bin/env bash
# audit-probe.sh [collect-audit args…]: runs collect-audit.sh, then prints PROBE lines
# about the bundle (which files exist, whether the gzipped transcript still carries a
# token) so a case can assert redaction through the gzip layer.
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

"$SWARM_LIB/collect-audit.sh" "$@"
rc=$?
printf 'PROBE: collect exit %s\n' "$rc"
dir=.swarm-run/audit
case " $* " in *" --critic-only "*) dir=.swarm-run/critic ;; esac
for f in "$dir"/*; do
  [ -e "$f" ] && printf 'PROBE: file %s\n' "${f#"$dir"/}"
done
for gz in "$dir"/*.gz; do
  [ -f "$gz" ] || continue
  if gzip -dc "$gz" | grep -qE 'ghs_[A-Za-z0-9]{20,}|hunter2'; then
    printf 'PROBE: %s carries a token\n' "${gz#"$dir"/}"
  else
    printf 'PROBE: %s redacted\n' "${gz#"$dir"/}"
  fi
  gzip -dc "$gz" | grep -q '\*\*\*' && printf 'PROBE: %s has stars\n' "${gz#"$dir"/}"
done
[ -f "$dir/perimeter.txt" ] && grep -q '## git status --porcelain' "$dir/perimeter.txt" && printf 'PROBE: perimeter has porcelain\n'
exit $rc
