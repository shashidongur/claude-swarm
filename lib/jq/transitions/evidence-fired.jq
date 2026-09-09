# evidence-fired — the claim of an evidence fire (§10.1, G39): counts the fire
# against the per-workflow cap inside the CAS, sets the pending wait with fired_at.
#   --arg workflow <slot> --arg head <sha> --arg consumer <role> [--arg cap 2] [--arg from_key K]
#   [--arg key K]   the wait key the caller computed with `state.sh next-key … evidence` (or the pending key on a re-fire)
#   routing facts as dispatch-queued
include "_lib";
state_pre
| (need("workflow")) as $w
| (need("head")) as $h
| (opt_int("cap"; 2)) as $cap
| pre((.status == "routing") or (.status == "evidence" and .evidence.pending != null and .evidence.pending.workflow == $w and .evidence.pending.head == $h and .evidence.pending.fired_at == null);
      "status is \(.status); an evidence fire starts from routing or an unfired pending wait")
| pre((has_arg("from_key") | not) or (.status != "routing") or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| pre(((.evidence.fires // {})[$w] // 0) < $cap; "evidence fire cap reached (\((.evidence.fires // {})[$w] // 0)/\($cap)) for \($w)")
| apply_facts
| (if .status == "evidence" then .evidence.pending.key else new_key(.stage; "evidence") end) as $k
| pre((has_arg("key") | not) or (arg("key") == $k); "evidence key \(opt("key"; "")) is stale; the next one is \($k)")
| (if .status == "evidence" then . else .stages[.stage].attempts.evidence = (((.stages[.stage].attempts // {}).evidence // 0) + 1) end)
| .evidence.fires[$w] = (((.evidence.fires // {})[$w] // 0) + 1)
| .status = "evidence"
| .gate = null
| .blocked = null
| .evidence.pending = { workflow: $w, key: $k, head: $h, fired_at: ts, run_id: 0, consumer: need("consumer") }
| log_event("evidence-fire"; null; "\($w) \($k)")
