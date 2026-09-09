# gate-reject — /swarm reject <why> at a gate (§6.3): free rework, budget reset,
# the reason kept for the target's brief. At budget the issue is parked instead.
#   --arg name <gate> --arg by <login> --arg reason <text ≥ 3 chars>
#   non-budget: --arg stage <target stage> --arg role <target role>
include "_lib";
state_pre
| (need("name")) as $g
| pre(.status == "gate"; "status is \(.status), not gate")
| pre(.gate.name == $g; "gate is \(.gate.name // "-"), not \($g)")
| (need("by")) as $by
| (need("reason") | tostring | .[0:4000]) as $why
| .totals.wakeups = ((.totals.wakeups // 0) + 1)
| .rework.spent = 0
| .rework.reset_at = ts
| .owner_reason = { kind: "reject", gate: $g, by: $by, at: ts, text: $why }
| (if $g == "budget" then
     .status = "parked" | .parked = { from: "gate", gate: "budget", at: ts, by: $by } | .gate = null
     | (if .next != null then .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null else . end)
   else
     (need("stage")) as $stage | (need("role")) as $role
     | queue($stage; $role; "reject")
     | .rework.log = ((.rework.log // []) + [{from: "owner:\($g)", to: $role, at: ts, key: .next.key, free: true}])
   end)
| log_event("reject"; $by; $why)
