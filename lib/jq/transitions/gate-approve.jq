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
     | .status = "queued"
     | .gate = null
     | .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null
   else
     queue(need("stage"); need("role"); opt("reason"; "approve"))
   end)
| log_event("approve"; $by; $g)
