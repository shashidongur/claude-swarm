#!/usr/bin/env bash
# fence.sh <label> < text: wrap untrusted text for the brief (§11.1).
#
#   <untrusted source="LABEL">
#   …the first 4,000 bytes; every `<untrusted` / `</untrusted` inside becomes `&lt;…`
#   so a payload cannot close (or nest) its own fence…
#   [truncated to 4000 of N bytes]            (only when cut)
#   </untrusted source="LABEL">
#
# Both sides carry the label so a reader (and the model) can pair them. The label is
# stripped of quotes, angle brackets and newlines. NUL bytes are dropped.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

LIMIT=${SWARM_FENCE_LIMIT:-4000}
label=$(printf '%s' "${1:-untrusted}" | tr -d '"<>\n\r')
[ -n "$label" ] || label=untrusted

tmp=$(tmpf .fence) || die "fence: cannot create a temp file"
tr -d '\000' > "$tmp"
total=$(wc -c < "$tmp" | tr -d ' ')

head -c "$LIMIT" "$tmp" > "$tmp.cut"
printf '<untrusted source="%s">\n' "$label"
sed -E 's#<(/?)([Uu][Nn][Tt][Rr][Uu][Ss][Tt][Ee][Dd])#\&lt;\1\2#g' "$tmp.cut"
# the body may not end in a newline; the closing tag must start its own line
if [ -s "$tmp.cut" ] && [ "$(tail -c 1 "$tmp.cut" | od -An -c | tr -d ' ')" != '\n' ]; then
  printf '\n'
fi
if [ "$total" -gt "$LIMIT" ]; then
  printf '[truncated to %s of %s bytes]\n' "$LIMIT" "$total"
fi
printf '</untrusted source="%s">\n' "$label"
rm -f "$tmp" "$tmp.cut"
