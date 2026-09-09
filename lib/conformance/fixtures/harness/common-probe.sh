#!/usr/bin/env bash
# common-probe.sh <helper> [args…]: runs one common.sh helper with the given
# arguments (stdin passed through) and prints "RC=<exit code>" last, so the common/
# cases can assert both the output and the status of a helper.
set -uo pipefail
SWARM_LIB="${SWARM_ROOT:?}/lib/sh"
# shellcheck source=lib/sh/common.sh
. "$SWARM_LIB/common.sh"

fn=${1:-}
shift || true
case $fn in
  marker|marker_get|marker_pred|find_comment|post_comment|edit_comment|reply|sanitize|fence|redact|stub_file|default_branch|owner_type|approvers_for|is_approver|slugify|matches_glob|job_minutes|yaml2json|gh_json|now)
    "$fn" "$@"
    rc=$?
    ;;
  *)
    die "common-probe: unknown helper ${fn}"
    ;;
esac
printf 'RC=%s\n' "$rc"
