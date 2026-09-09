# dispatch-died — the claimed run ended without a valid result (G21). Records the
# death; status running → routing so the caller can retry (dispatch-queued), back
# off (dispatch-queued --arg not_before) or block.
#   --arg key K --arg run_id R --arg died_reason max-turns|timeout|cancelled|error|auth|ratelimit [--argjson stats {…}]
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(.current.key == $k and .current.run_id == $rid; "current is \(.current.key // "-")/\(.current.run_id // "-"), not \($k)/\($rid)")
| pre((rec($k; $rid) | .status) == "running"; "record (\($k), \($rid)) is \(rec($k; $rid) | .status // "absent"), not running")
| (stats_arg | .died_reason = need("died_reason") | .verdict = null) as $st
| update_rec($k; $rid; record_terminal($st; "died"))
| add_totals($st)
| (if .status == "running" then .status = "routing" else . end)
| log_event("died"; null; "\($k) \(need("died_reason"))")
