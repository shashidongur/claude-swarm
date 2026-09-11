# dispatch-unclaim — the run job was cancelled before it started (the one-pending-
# slot rule): the record becomes cancelled-pending and the same key is re-queued.
#   --arg key K --arg run_id <the cancelled run>
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(.status | IN("running", "routing"); "status is \(.status), not running")
| pre(.current.key == $k and .current.run_id == $rid; "current is \(.current.key // "-")/\(.current.run_id // "-"), not \($k)/\($rid)")
| pre((rec($k; $rid) | .status) == "running"; "record (\($k), \($rid)) is \(rec($k; $rid) | .status // "absent"), not running")
| update_rec($k; $rid; .status = "cancelled-pending" | .finished_at = ts)
| .status = "queued"
| .next = {stage: .stage, role: .current.role, key: $k, fired_at: null, fired_by: null, fired_run_id: null, not_before: null, reason: "requeue"}
| log_event("unclaim"; null; "\($k) run \($rid) cancelled before it started")
