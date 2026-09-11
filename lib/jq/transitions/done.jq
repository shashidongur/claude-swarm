# done — retro finished: the issue is complete. Records the memory PR or patch artifact.
#   [--arg from_key K] [--arg memory_pr N] [--arg memory_artifact <name>]
include "_lib";
state_pre
| pre(.status | IN("routing", "queued", "evidence", "gate", "blocked", "parked"); "status is \(.status)")
| pre((has_arg("from_key") | not) or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| .stages.retro.status = "done"
| .status = "done"
| .next = null | .gate = null | .blocked = null | .parked = null | .evidence.pending = null
| (if has_arg("memory_pr") then .memory.pr = (arg("memory_pr") | toint) else . end)
| (if has_arg("memory_artifact") then .memory.artifact = arg("memory_artifact") else . end)
| log_event("done")
