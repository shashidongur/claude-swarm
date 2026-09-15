# block — a terminal wait-state (§5): swarm:blocked + blocked:<reason>. `fire` keeps
# `next` with its fire fields reset so /swarm resume re-fires it; `stalled` leaves
# `current` untouched so a re-run or a finalize can still finish the record.
#   --arg reason agent-output|role-stopped|budget|runaway|evidence|stalled|fire|injection|duplicate|conflict|bad-handoff|perimeter|auth|model
#   [--arg detail <≤ 600 chars, already redacted>] [--arg comment_id N] [--arg from_key K]
include "_lib";
state_pre
| (need("reason")) as $r
| pre($r | IN("agent-output", "role-stopped", "budget", "runaway", "evidence", "stalled", "fire", "injection", "duplicate", "conflict", "bad-handoff", "perimeter", "auth", "model"); "unknown block reason \($r)")
| pre(.status | IN("done", "dropped") | not; "status is \(.status)")
| pre((has_arg("from_key") | not) or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| .blocked = { reason: $r, detail: (opt("detail"; "") | tostring | .[0:600]), at: ts,
               comment_id: (if has_arg("comment_id") then (arg("comment_id") | toint) else null end), from: .status }
| (if $r == "fire" and .next != null then .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null else . end)
| (if $r == "fire" and .evidence.pending != null and .status == "evidence" then .evidence.pending.fired_at = null else . end)
| .status = "blocked"
| .gate = null
| .parked = null
| log_event("blocked"; null; "\($r): \(opt("detail"; "") | tostring | .[0:120])")
