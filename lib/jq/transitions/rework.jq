# rework — a budgeted rework edge (code-review / qa / security / compliance / a11y /
# threat-model / critic / CI-red): spends one unit of the budget (G7 inside the
# CAS), queues the target at attempt+1, keeps the reason for the target's brief.
#   --arg from <role that asked> --arg to <role[:lane]> --arg stage <the target's stage>
#   [--arg reason …] [--arg free true] [--arg from_key K] [--arg not_before ISO]
#   [--arg critic_rework true]   the critic asked (§8.4): stages[<stage>].critic_reworks++
#   routing facts as dispatch-queued
include "_lib";
state_pre
| pre(.status | IN("routing", "evidence"); "status is \(.status), not routing/evidence")
| pre((has_arg("from_key") | not) or (.status == "routing" and .current.key == arg("from_key")) or (.status == "evidence" and .evidence.pending.key == arg("from_key"));
      "from_key \(opt("from_key"; "")) is neither current.key nor the pending evidence key")
| (opt("free"; "false") == "true") as $free
| pre($free or ((.rework.spent // 0) < (.rework.budget // 0)); "rework budget exhausted (\(.rework.spent)/\(.rework.budget))")
| apply_facts
| (if $free then . else .rework.spent = ((.rework.spent // 0) + 1) end)
| (if opt("critic_rework"; "false") == "true" then .stages[.stage].critic_reworks = ((.stages[.stage].critic_reworks // 0) + 1) else . end)
| .totals.reworks = ((.totals.reworks // 0) + 1)
| queue(need("stage"); need("to"); "rework"; opt("not_before"; null))
# Capped like .log: this document is rewritten under CAS on every transition, so an
# unbounded list makes every later write larger and slower for the life of the issue.
| .rework.log = (((.rework.log // []) + [{from: need("from"), to: need("to"), at: ts, key: .next.key, free: $free, reason: (opt("reason"; "") | tostring | .[0:2000])}]) | .[-50:])
| log_event("rework"; null; "\(need("from")) → \(need("to"))")
