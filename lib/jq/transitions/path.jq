# path — the full/short decision (triage), an escalation (analyst) or the owner's
# override. Short skips design and architecture; a dissolved gate queues the next
# stage when the caller names it.
#   --arg path full|short [--arg source triage|analyst|owner] [--arg by <login>]
#   [--arg next_stage S --arg next_role R]   (queues it; from gate/routing)
include "_lib";
state_pre
| (need("path")) as $p
| pre($p | IN("full", "short"); "path must be full or short")
| pre(.status | IN("running", "done", "dropped") | not; "status is \(.status)")
| .path = $p
| .path_source = opt("source"; "owner")
| (if $p == "short" then
     .stages.design.status = (if .stages.design.status == "pending" then "skipped" else .stages.design.status end)
     | .stages.architecture.status = (if .stages.architecture.status == "pending" then "skipped" else .stages.architecture.status end)
   else
     .stages.design.status = (if .stages.design.status == "skipped" then "pending" else .stages.design.status end)
     | .stages.architecture.status = (if .stages.architecture.status == "skipped" then "pending" else .stages.architecture.status end)
   end)
| (if has_arg("next_stage") then queue(arg("next_stage"); need("next_role"); "path") else . end)
| log_event("path"; opt("by"; null); "\($p) (\(.path_source))")
