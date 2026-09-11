# dispatch-queued — the routing decision: the next dispatch, in the same CAS as the
# facts that led to it. Increments the attempt counter (via queue).
#   --arg stage <stage> --arg role <role[:lane]> [--arg reason chain|rework|retry|evidence|…]
#   [--arg from_key K]       must equal current.key (status routing) or evidence.pending.key (status evidence)
#   [--arg not_before ISO]   the ratelimit back-off
#   [--arg model <id>]       model_requested on the record
#   routing facts: [--arg done_stage] [--arg done_lane] [--argjson triage] [--arg path] [--arg path_source]
#                  [--argjson lanes] [--argjson subissues] [--arg head] [--arg pr]
include "_lib";
state_pre
| pre(.status | IN("routing", "evidence"); "status is \(.status), not routing/evidence")
| pre((has_arg("from_key") | not) or (.status == "routing" and .current.key == arg("from_key")) or (.status == "evidence" and .evidence.pending.key == arg("from_key"));
      "from_key \(opt("from_key"; "")) is neither current.key (\(.current.key // "-")) nor the pending evidence key")
| apply_facts
| queue(need("stage"); need("role"); opt("reason"; "chain"); opt("not_before"; null))
| log_event("queued"; null; .next.key)
