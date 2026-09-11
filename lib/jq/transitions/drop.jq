# drop — /swarm drop: abandoned; work kept (branch, PR), nothing fires again
# except a merge (pr-merged is admissible from any status).
#   [--arg by <login>] [--arg note …]
include "_lib";
state_pre
| pre(.status != "dropped"; "already dropped")
| .status = "dropped"
| .gate = null
| .blocked = null
| .parked = null
| .next = null
| .evidence.pending = null
| log_event("drop")
