#!/usr/bin/env bash
# memory-index.sh — regenerates the index files of a project's memory folder
# (spec §12.1, §12.3): gotchas/INDEX.md, adrs/INDEX.md, postmortems/INDEX.md.
#
#   memory-index.sh <memory-dir>          e.g. memory/github.com/<owner>/<repo>
#
# Each index keeps its header (everything before the first `- [` line, or the whole
# file when it has no entries) and lists one line per note found:
#   - [<name>](<relative path>) — <description>
# An entry that already exists for a file is kept verbatim (curated wording wins);
# entries for missing files are dropped; new files get a line from their
# frontmatter `name`/`description` (the file's stem when absent). Machine-written
# gotchas under gotchas/auto/ are listed in gotchas/INDEX.md under a
# `## Proposed (auto — read fenced until promoted)` heading, separately from the
# curated ones. Exit 0; a missing folder is a `::warning::`, not an error.
set -uo pipefail
SWARM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

DIR=${1:-}
[ -n "$DIR" ] || die "usage: memory-index.sh <memory-dir>"
[ -d "$DIR" ] || { printf '::warning::memory-index: %s is not a directory; nothing regenerated\n' "$DIR"; exit 0; }

frontmatter_field() { # <file> <key> → the value (unquoted) or nothing
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }' "$1"
}

entry_line() { # <file> <relative path> → "- [name](path) — description"
  local name desc
  name=$(frontmatter_field "$1" name)
  desc=$(frontmatter_field "$1" description)
  [ -n "$name" ] || name=$(basename "$1" .md)
  name=$(printf '%s' "$name" | sanitize | tr -d '\r\n')
  desc=$(printf '%s' "$desc" | sanitize | tr -d '\r\n' | cut -c1-160)
  printf -- '- [%s](%s)%s\n' "$name" "$2" "${desc:+ — $desc}"
}

# regenerate <index file> <default header> <files glob dir> [auto dir]
regenerate() {
  local index=$1 header=$2 sub=$3 auto=${4:-} tmp f rel existing line
  tmp=$(tmpf .md) || die "memory-index: no temp dir"
  if [ -f "$index" ]; then
    awk '/^- \[/ { exit } { print }' "$index" > "$tmp"
    [ -s "$tmp" ] || printf '%s\n\n' "$header" > "$tmp"
  else
    printf '%s\n\n' "$header" > "$tmp"
  fi
  # the curated files
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$DIR/$sub/"}
    case $rel in INDEX.md|auto/*) continue ;; esac
    existing=""
    [ -f "$index" ] && existing=$(grep -F -m1 -- "]($rel)" "$index" | grep -E '^- \[' || true)
    if [ -n "$existing" ]; then printf '%s\n' "$existing" >> "$tmp"; else entry_line "$f" "$rel" >> "$tmp"; fi
  done < <(find "$DIR/$sub" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  if [ -n "$auto" ] && [ -d "$DIR/$sub/$auto" ]; then
    line=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="$auto/$(basename "$f")"
      [ -n "$line" ] || { printf '\n## Proposed (auto — read fenced until promoted)\n\n' >> "$tmp"; line=1; }
      existing=""
      [ -f "$index" ] && existing=$(grep -F -m1 -- "]($rel)" "$index" | grep -E '^- \[' || true)
      if [ -n "$existing" ]; then printf '%s\n' "$existing" >> "$tmp"; else entry_line "$f" "$rel" >> "$tmp"; fi
    done < <(find "$DIR/$sub/$auto" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  fi
  if ! grep -qE '^- \[' "$tmp"; then printf '(none yet)\n' >> "$tmp"; fi
  mkdir -p "$(dirname "$index")"
  mv -f "$tmp" "$index"
  log "memory-index: $index regenerated ($(grep -cE '^- \[' "$index") entries)"
}

[ -d "$DIR/gotchas" ] && regenerate "$DIR/gotchas/INDEX.md" "# Gotchas" gotchas auto
[ -d "$DIR/adrs" ] && regenerate "$DIR/adrs/INDEX.md" "# ADRs" adrs
[ -d "$DIR/postmortems" ] && regenerate "$DIR/postmortems/INDEX.md" "# Post-mortems" postmortems
exit 0
