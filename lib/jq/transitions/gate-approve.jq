# gate-approve — /swarm approve at a gate (§6.3). Records the approver, counts the
# wake-up, and queues what follows: the given stage/role, or — at budget — the
# queued next with the raised cap.
#   --arg name <gate> --arg by <login> [--arg comment_id N]
#   non-budget: --arg stage <next stage> --arg role <its first role> [--arg reason approve]
#   budget:     --arg cap <new cost_usd_per_issue for this issue>
include "_lib";
state_pre
| (need("name")) as $g
| pre(.status == "gate"; "status is \(.status), not gate")
| pre(.gate.name == $g; "gate is \(.gate.name // "-"), not \($g)")
| (need("by")) as $by
| .totals.wakeups = ((.totals.wakeups // 0) + 1)
| (if $g | IN("requirements", "architecture", "confidence") then
     .stages[.stage].approved = { by: $by, at: ts } + (if has_arg("comment_id") then {comment_id: (arg("comment_id") | toint)} else {} end)
   else . end)
| (if $g == "budget" then
     pre(.next != null; "budget gate without a queued next")
     | .limits.cost_usd_per_issue = (opt("cap"; null) | if . == null then null else toint end)
     # The same gate is raised by the per-issue cost cap (G30) and by the monthly
     # runner brake (G31), and only the first is a per-issue limit. Without a waiver
     # the approve is a no-op against the brake: brakes() re-reads the same monthly
     # figure and gates again, so every press posts a contradictory approve→gate pair
     # and the only ways out are /swarm drop, editing the config on the default
     # branch, or the month rolling over. The waiver buys exactly one envelope of
     # runner minutes for this issue, measured from what it has spent so far.
     | .limits.brake_waived_at = ts
     | .limits.brake_waived_minutes = ((.totals.runner_minutes // 0))
     | .status = "queued"
     | .gate = null
     | .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null
   else
     queue(need("stage"); need("role"); opt("reason"; "approve"))
   end)
| log_event("approve"; $by; $g)
