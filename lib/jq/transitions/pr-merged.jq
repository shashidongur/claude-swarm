# pr-merged — an approver merged the PR (G35 already passed): recorded once, the
# pending next cancelled, gates dissolved, retro queued — from any status.
#   --arg pr N --arg by <login> [--arg merge_sha <sha>] [--arg merged_at ISO]
#   [--arg stage retro --arg role retro]
include "_lib";
state_pre
| pre(.merged_at == null; "already merged at \(.merged_at) (PR #\(.merged_pr // "?"))")
| pre((.stages.retro.status // "pending") == "pending"; "retro is \(.stages.retro.status)")
| (need("pr") | toint) as $pr
| .merged_at = opt("merged_at"; ts)
| .merged_pr = $pr
| .merge_sha = opt("merge_sha"; null)
| .merged_by = need("by")
| (if .pr == null then .pr = $pr else . end)
| .stages.release.status = (if .stages.release.status | IN("pending", "running") then "done" else .stages.release.status end)
| .owner_reason = null
| queue(opt("stage"; "retro"); opt("role"; "retro"); "merged")
| log_event("merged"; need("by"); "PR #\($pr)")
