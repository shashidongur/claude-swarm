# dispatch-finished — the run completed with a valid result (§4.4): record, cost,
# verdict, head kept whatever the status; status running → routing, else unchanged
# (parked, dropped, blocked:stalled keep the record and route nothing).
#   --arg key K --arg run_id R --arg verdict pass|rework|blocked|question|duplicate
#   --argjson stats '{cost_usd, turns, duration_s, job_minutes, overhead_minutes, model_requested, model_actual,
#                     retry, head, artifact, handoff, validation, last_text, critic}'
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(.current.key == $k and .current.run_id == $rid; "current is \(.current.key // "-")/\(.current.run_id // "-"), not \($k)/\($rid)")
| pre((rec($k; $rid) | .status) == "running"; "record (\($k), \($rid)) is \(rec($k; $rid) | .status // "absent"), not running")
| (stats_arg | .verdict = need("verdict")) as $st
| update_rec($k; $rid; record_terminal($st; "finished"))
| add_totals($st)
| (if ($st.head | type) == "string" and ($st.head | length) == 40 then .head = $st.head else . end)
| (if ($st.critic | type) == "object" and ($st.critic.score != null) then .stages[.stage].critic = ($st.critic | {score, threshold, verdict}) else . end)
| (if .status == "running" then .status = "routing" else . end)
| log_event("finished"; null; "\($k) \(need("verdict"))")
