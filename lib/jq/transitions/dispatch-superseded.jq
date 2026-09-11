# dispatch-superseded — a queued or running record whose stage is now carried by a
# newer dispatch (a resume/redo while it was presumed dead). Marks the record only.
#   --arg key K --arg run_id R [--arg by <event description>]
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| pre(rec($k; $rid) != null; "no record (\($k), \($rid))")
| pre((rec($k; $rid) | .status) | IN("queued", "running"); "record (\($k), \($rid)) is already \(rec($k; $rid) | .status)")
| update_rec($k; $rid; .status = "superseded" | .finished_at = ts | .superseded_by = opt("by"; null))
| log_event("superseded"; null; "\($k) run \($rid) \(opt("by"; ""))")
