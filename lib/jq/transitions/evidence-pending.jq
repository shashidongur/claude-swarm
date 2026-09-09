# evidence-pending — wait for a run the dispatcher did not fire (CI on a pushed
# head): status → evidence with the wait keyed <issue>:<stage>:evidence:<n> (a
# counter). When the same wait is already pending only run_id is refreshed.
#   --arg workflow <slot, e.g. ci> --arg head <sha> --arg consumer <role> [--arg run_id N] [--arg from_key K]
#   [--arg key K]   the wait key the caller computed with `state.sh next-key … evidence`; must still be the next one
#   routing facts as dispatch-queued
include "_lib";
state_pre
| (need("workflow")) as $w
| (need("head")) as $h
| pre(.status | IN("routing", "evidence"); "status is \(.status), not routing/evidence")
| pre((has_arg("from_key") | not) or (.status != "routing") or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| apply_facts
| (opt_int("run_id"; 0)) as $rid
| if .status == "evidence" and .evidence.pending != null and .evidence.pending.workflow == $w and .evidence.pending.head == $h then
    .evidence.pending.run_id = (if $rid > 0 then $rid else .evidence.pending.run_id end)
    | .evidence.pending.consumer = need("consumer")
  else
    new_key(.stage; "evidence") as $k
    | pre((has_arg("key") | not) or (arg("key") == $k); "evidence key \(opt("key"; "")) is stale; the next one is \($k)")
    | .stages[.stage].attempts.evidence = (((.stages[.stage].attempts // {}).evidence // 0) + 1)
    | .status = "evidence"
    | .gate = null
    | .blocked = null
    | .evidence.pending = { workflow: $w, key: $k, head: $h, fired_at: null, run_id: $rid, consumer: need("consumer") }
    | log_event("evidence-wait"; null; "\($w) on \($h[0:7]) → \(need("consumer"))")
  end
