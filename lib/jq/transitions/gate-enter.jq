# gate-enter — a wait-state for a human (§6.4). From routing for requirements /
# architecture / release / confidence / question; from queued (next kept) for budget.
#   --arg name requirements|architecture|release|question|confidence|budget
#   [--arg from_key K] [--arg comment_id N] [--arg escalated_role r] [--arg note …]
#   routing facts as dispatch-queued
include "_lib";
state_pre
| (need("name")) as $g
| pre($g | IN("requirements", "architecture", "release", "question", "confidence", "budget"); "unknown gate \($g)")
| pre((.status == "routing") or (.status == "queued" and $g == "budget"); "status is \(.status), not routing")
| pre((has_arg("from_key") | not) or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| pre($g != "budget" or .next != null; "budget gate needs a queued next")
| apply_facts
| (if $g == "question" then
     pre(.questions.rounds < (.questions.max // 2); "question rounds exhausted (\(.questions.rounds)/\(.questions.max))")
     | .questions.rounds += 1
     | .questions.comment_id = (if has_arg("comment_id") then (arg("comment_id") | toint) else null end)
   else . end)
| .status = "gate"
| .gate = { name: $g, since: ts, comment_id: (if has_arg("comment_id") then (arg("comment_id") | toint) else null end), reminded_at: null }
  + (if has_arg("escalated_role") then {escalated_role: arg("escalated_role")} else {} end)
| .blocked = null
| log_event("gate"; null; $g)
