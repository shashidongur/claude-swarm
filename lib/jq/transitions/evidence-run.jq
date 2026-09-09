# evidence-run — records the run id of the pending evidence wait (after fire-and-
# verify, or when GitHub reports an in-flight run for the head).
#   --arg key <pending key> --arg run_id N
include "_lib";
state_pre
| pre(.status == "evidence" and .evidence.pending != null; "status is \(.status), not evidence")
| pre(.evidence.pending.key == need("key"); "pending key is \(.evidence.pending.key), not \(arg("key"))")
| .evidence.pending.run_id = (need("run_id") | toint)
