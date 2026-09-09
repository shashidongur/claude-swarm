# log — append a human/machine event; optionally refresh the per-event facts.
#   --arg event <name> [--arg by <login>] [--arg note …] [--arg config_sha <sha>] [--arg v1_history true]
include "_lib";
state_pre
| (if has_arg("config_sha") then .config_sha = arg("config_sha") else . end)
| (if has_arg("v1_history") then .flags.v1_history = (arg("v1_history") == "true") else . end)
| log_event(need("event"))
