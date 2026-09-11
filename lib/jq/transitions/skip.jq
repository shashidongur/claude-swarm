# skip — /swarm skip <stage> [why]: the stage is skipped_by_owner; when it is the
# current stage the caller says what follows (a gate that is still enforced, or the
# next stage's first role).
#   --arg stage S --arg by <login> [--arg reason …]
#   [--arg gate <name>]  or  [--arg next_stage S2 --arg next_role R]
include "_lib";
state_pre
| (need("stage")) as $s
| pre(.status | IN("running", "routing") | not; "status is \(.status)")
| pre($s | IN("triage", "build", "release", "retro") | not; "\($s) cannot be skipped")
| pre((.stages // {}) | has($s); "unknown stage \($s)")
| pre(stage_index($s) >= stage_index(.stage); "\($s) is already behind the current stage \(.stage)")
| (need("by")) as $by
| .stages[$s] |= (. + {status: "skipped_by_owner", reason: (opt("reason"; "") | tostring | .[0:500]), skipped_by: $by})
| .owner_reason = { kind: "skip", stage: $s, by: $by, at: ts, text: (opt("reason"; "") | tostring | .[0:4000]) }
| (if $s == .stage then
     (if has_arg("gate") then
        .status = "gate" | .next = null | .evidence.pending = null | .blocked = null | .parked = null
        | .gate = { name: arg("gate"), since: ts, comment_id: null, reminded_at: null }
      elif has_arg("next_stage") then
        queue(arg("next_stage"); need("next_role"); "skip")
      else pre(false; "skipping the current stage needs --arg gate or --arg next_stage/next_role") end)
   else . end)
| log_event("skip"; $by; $s)
