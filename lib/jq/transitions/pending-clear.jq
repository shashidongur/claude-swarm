# pending-clear — the staged file was seen on a pushed head (V7): the entry goes.
# Clearing an entry that is not there changes nothing (and writes nothing).
#   --arg file <path>
include "_lib";
state_pre
| .pending_artifacts = [(.pending_artifacts // [])[] | select(.file != need("file"))]
