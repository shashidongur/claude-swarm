#!/usr/bin/env bash
# render.sh — renders a lib/templates/<name>.tmpl into a file (spec §16.1.3).
#
#   render.sh <template> <out> [--arg k v]… [--argjson k json]… [--rawfile k file]…
#                              [--sarg k v]… [--srawfile k file]…
#   render.sh state   <state.json> <out> [--arg k v]…      the state comment (lib/jq/render-state.jq)
#   render.sh comment <input.json> <out> [--arg k v]…      the stage comment (lib/jq/render-comment.jq)
#
# `{{var}}` placeholders are substituted with jq; a placeholder with no value is an
# error (exit 1, nothing written), never an empty string in a comment a human reads.
# `--argjson` values render as JSON text; `--rawfile` reads a file verbatim. Untrusted
# values are pre-sanitised by the caller (common.sh `sanitize`); `--sarg`/`--srawfile`
# do that here as a convenience. `<out>` may be `-` for stdout. Template names
# `state` and `comment` are reserved for the two jq renderers.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

usage() {
  sed -n '2,16p' "$0" >&2
  exit 1
}

[ $# -ge 2 ] || usage
mode=template
case $1 in
  state|comment)
    mode=$1
    shift
    [ $# -ge 2 ] || usage
    input=$1
    [ -f "$input" ] || die "render: no such input file: $input"
    ;;
  *) ;;
esac
name=$1
outp=$2
shift 2

jqargs=()
while [ $# -gt 0 ]; do
  case $1 in
    --arg|--argjson|--rawfile)
      [ $# -ge 3 ] || die "render: $1 needs a name and a value"
      jqargs+=("$1" "$2" "$3")
      shift 3 ;;
    --sarg)
      [ $# -ge 3 ] || die "render: --sarg needs a name and a value"
      v=$(printf '%s' "$3" | sanitize)
      jqargs+=(--arg "$2" "$v")
      shift 3 ;;
    --srawfile)
      [ $# -ge 3 ] || die "render: --srawfile needs a name and a file"
      [ -f "$3" ] || die "render: no such file: $3"
      v=$(sanitize < "$3")
      jqargs+=(--arg "$2" "$v")
      shift 3 ;;
    *) die "render: unknown option $1" ;;
  esac
done

tmp=$(tmpf .render) || die "render: cannot create a temporary file"
rc=0
case $mode in
  state)
    jq -r "${jqargs[@]}" -f "$SWARM_ROOT/lib/jq/render-state.jq" "$input" > "$tmp" || rc=$?
    ;;
  comment)
    jq -r "${jqargs[@]}" -f "$SWARM_ROOT/lib/jq/render-comment.jq" "$input" > "$tmp" || rc=$?
    ;;
  template)
    tmpl="$SWARM_ROOT/lib/templates/${name%.tmpl}.tmpl"
    [ -f "$tmpl" ] || { rm -f "$tmp"; die "render: no such template: ${name%.tmpl} (lib/templates/)"; }
    jq -j -n --rawfile t "$tmpl" "${jqargs[@]}" '
      $t | gsub("\\{\\{(?<k>[A-Za-z0-9_]+)\\}\\}";
        . as $c
        | if ($ARGS.named | has($c.k))
          then ($ARGS.named[$c.k] | if type == "string" then . else tojson end)
          else error("missing template variable: " + $c.k) end)' > "$tmp" || rc=$?
    ;;
esac

if [ $rc -ne 0 ]; then
  rm -f "$tmp"
  die "render: $mode '$name' failed (exit $rc)"
fi
if [ "$outp" = "-" ]; then
  cat "$tmp"
  rm -f "$tmp"
else
  mv -f "$tmp" "$outp" || die "render: cannot write $outp"
fi
exit 0
