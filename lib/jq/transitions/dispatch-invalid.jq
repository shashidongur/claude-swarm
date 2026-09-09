# dispatch-invalid — the run ended but result.json failed the authoritative
# validation after the retry (G20). Same shape as dispatch-died.
#   --arg key K --arg run_id R [--argjson stats {…, validation: {ok:false, errors:[…]}}]
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(.current.key == $k and .current.run_id == $rid; "current is \(.current.key // "-")/\(.current.run_id // "-"), not \($k)/\($rid)")
| pre((rec($k; $rid) | .status) == "running"; "record (\($k), \($rid)) is \(rec($k; $rid) | .status // "absent"), not running")
| (stats_arg | .verdict = null) as $st
| update_rec($k; $rid; record_terminal($st; "invalid"))
| add_totals($st)
| (if .status == "running" then .status = "routing" else . end)
| log_event("invalid"; null; $k)
