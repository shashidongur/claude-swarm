# stage-done — marks a stage done (and its lanes) without queueing anything; the
# routing transitions accept the same fact as --arg done_stage in one CAS.
#   --arg stage S [--arg from_key K]
include "_lib";
state_pre
| (need("stage")) as $s
| pre((.stages // {}) | has($s); "unknown stage \($s)")
| pre((has_arg("from_key") | not) or (.current.key == arg("from_key")); "current.key is \(.current.key // "-"), not \(opt("from_key"; ""))")
| .stages[$s].status = "done"
| .stages[$s].lanes = ((.stages[$s].lanes // {}) | with_entries(.value = "done"))
| log_event("stage-done"; null; $s)
