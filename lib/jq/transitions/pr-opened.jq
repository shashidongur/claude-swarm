# pr-opened — the draft PR the test-writer opened (recorded by advance).
#   --arg pr N [--arg branch <name>] [--arg head <sha>]
include "_lib";
state_pre
| (need("pr") | toint) as $pr
| pre(.pr == null or .pr == $pr; "PR is already #\(.pr), not #\($pr)")
| .pr = $pr
| (if has_arg("branch") then .branch = arg("branch") else . end)
| (if has_arg("head") then .head = arg("head") else . end)
| log_event("pr-opened"; null; "#\($pr)")
