# redo — /swarm redo <stage> [why] (§6.3): free, budget reset, later stages back to
# pending (attempt counters are never reset), swarm code re-pinned.
#   --arg stage S --arg role <its first role> --arg by <login> [--arg reason …] [--arg swarm_sha <sha>]
include "_lib";
state_pre
| (need("stage")) as $s
| pre(.status | IN("running", "routing") | not; "status is \(.status); wait for the stage to finish or park first")
| pre(.merged_at == null; "already merged at \(.merged_at)")
| pre((.stages // {}) | has($s); "unknown stage \($s)")
| (need("by")) as $by
| .rework.spent = 0
| .rework.reset_at = ts
| (if has_arg("swarm_sha") then .swarm_sha = arg("swarm_sha") else . end)
| .stages = (.stages | with_entries(
    if stage_index(.key) > stage_index($s) then
      .value = ({status: (if .value.status == "skipped" then "skipped" else "pending" end), attempts: (.value.attempts // {})})
    else . end))
| .stages[$s] |= (del(.approved) | del(.critic) | .critic_reworks = 0 | .lanes = ((.lanes // {}) | with_entries(.value = "pending")))
| .owner_reason = { kind: "redo", stage: $s, by: $by, at: ts, text: (opt("reason"; "") | tostring | .[0:4000]) }
| queue($s; need("role"); "redo")
| .rework.log = ((.rework.log // []) + [{from: "owner:redo", to: need("role"), at: ts, key: .next.key, free: true}])
| log_event("redo"; $by; "\($s) \(opt("reason"; ""))")
