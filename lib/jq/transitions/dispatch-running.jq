# dispatch-running — the claim (§4.4): resolve accepts the stub run for state.next.
#   --arg key K --arg run_id <this run> [--arg run_attempt 1] [--arg base_sha <sha>] [--arg model <id>]
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(.status == "queued"; "status is \(.status), not queued")
| pre(.next.key == $k; "next.key is \(.next.key // "-"), not \($k)")
| pre((.next.fired_run_id == null) or (.next.fired_run_id == $rid); "fired run is \(.next.fired_run_id), not \($rid)")
| pre((.next.not_before == null) or ((.next.not_before | epoch) <= (ts | epoch)); "not before \(.next.not_before)")
| pre(rec($k; $rid) == null; "key reuse: (\($k), \($rid)) already has a record")
| (opt_int("run_attempt"; 1)) as $ra
| (opt("base_sha"; null)) as $base
| .stage = .next.stage
| .current = {
    role: .next.role, attempt: attempt_of_key($k), key: $k, run_id: $rid, run_attempt: $ra,
    comment_id: null, started_at: ts, claimed_at: ts, base_sha: $base, activity_from: ts,
    fired_run_id: .next.fired_run_id }
| .status = "running"
| ((.dispatches // []) | map(.key == $k and .status == "queued") | index(true)) as $i
| (if $i != null then
     .dispatches[$i] |= (. + {run_id: $rid, status: "running", claimed_at: ts, run_attempt: $ra, base_sha: $base}
                          + (if has_arg("model") then {model_requested: arg("model")} else {} end))
   else
     .dispatches = ((.dispatches // []) + [{
       key: $k, run_id: $rid, stage: .next.stage, role: .next.role, attempt: attempt_of_key($k), run_attempt: $ra, at: ts,
       claimed_at: ts, finished_at: null, status: "running", verdict: null,
       model_requested: opt("model"; null), model_actual: null, cost_usd: 0, turns: 0, duration_s: 0, job_minutes: 0,
       retry: 0, critic: null, base_sha: $base, head: null, artifact: null, handoff: null, died_reason: null,
       validation: null, last_text: null, reason: (.next.reason // null) }])
   end)
| .next = null
| cap_dispatches
| log_event("claim"; null; "\($k) run \($rid)")
