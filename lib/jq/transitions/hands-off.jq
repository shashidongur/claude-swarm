# hands-off — the per-issue veto flag (label or command). Cleared only when the
# label is gone by hand (--arg value false, written by resolve on the next event).
#   [--arg value true|false] [--arg by <login>]
include "_lib";
state_pre
| (opt("value"; "true") == "true") as $v
| .flags.hands_off = $v
| log_event(if $v then "hands-off" else "hands-off-cleared" end)
