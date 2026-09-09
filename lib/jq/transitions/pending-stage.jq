# pending-stage — a read-role artifact staged on the state branch (§9.1): recorded
# with its sha256 so the copy can be verified and never swapped.
#   --arg file <path relative to <artifacts_dir>/<N>/> --arg sha256 <hex>
include "_lib";
state_pre
| (need("file")) as $f
| (need("sha256")) as $s
| pre($s | test("^[0-9a-f]{64}$"); "sha256 must be 64 hex chars")
| .pending_artifacts = ([(.pending_artifacts // [])[] | select(.file != $f)] + [{file: $f, sha256: $s}])
