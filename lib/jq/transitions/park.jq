# park — /swarm park or a PR closed unmerged: nothing fires until resume; a running
# stage finishes and is recorded (dispatch-finished accepts parked).
#   [--arg by <login>] [--arg note …]
include "_lib";
state_pre
| pre(.status | IN("done", "dropped") | not; "status is \(.status)")
| .parked = { from: .status, at: ts, by: opt("by"; null) } + (if .gate != null then {gate: .gate.name} else {} end)
| .status = "parked"
| .gate = null
| .blocked = null
| (if .next != null then .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null else . end)
| log_event("park")
