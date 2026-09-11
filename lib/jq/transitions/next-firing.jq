# next-firing — the fire claim (§3.5): only one writer may call `gh workflow run`.
#   --arg key K --arg run_id <firing run> [--arg refire_minutes 30]
include "_lib";
state_pre
| pre(.status == "queued"; "status is \(.status), not queued")
| pre(.next.key == need("key"); "next.key is \(.next.key // "-"), not \(arg("key"))")
| pre((.next.not_before == null) or ((.next.not_before | epoch) <= (ts | epoch)); "not before \(.next.not_before)")
| pre((.next.fired_at == null) or (((ts | epoch) - (.next.fired_at | epoch)) > (opt_int("refire_minutes"; 30) * 60));
      "already fired at \(.next.fired_at) by run \(.next.fired_by // "-")")
| .next.fired_at = ts
| .next.fired_by = run_id
| .next.fired_run_id = null
| log_event("fire"; null; .next.key)
