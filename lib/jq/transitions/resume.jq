# resume — /swarm resume, by case (§6.3):
#   --arg mode next      fire `next` (blocked:fire, parked-with-next, queued): status queued, fire fields reset
#   --arg mode retry     re-run current.role at attempt+1 (other blocked, parked without next); a still-running record is superseded
#   --arg mode finalize  blocked:stalled with a completed run: back to the status the block interrupted, so advance finalises from the handoff
#   --arg mode route     the current record is already `finished` and nothing is queued (parked or blocked mid-stage, or dropped): status routing, so the next run's reconcile routes on instead of re-running a role that already ran
#   --arg mode evidence  re-query the pending evidence wait (blocked:evidence/fire or status evidence): status evidence, fired_at reset
#   --arg mode question  proceed on stated assumptions (or an answer): queue analyst at attempt+1
#   [--arg by <login>] [--arg note …] [--arg stage S --arg role R] (retry/question: override the target)
include "_lib";
state_pre
| (need("mode")) as $m
| (.status) as $was
| if $m == "next" then
    pre(.next != null; "nothing queued to fire")
    | pre(.status | IN("blocked", "parked", "queued", "dropped"); "status is \(.status)")
    | .status = "queued"
    | .next.fired_at = null | .next.fired_by = null | .next.fired_run_id = null | .next.not_before = null
    | .blocked = null | .parked = null | .gate = null
  elif $m == "route" then
    # The role ran, pushed and was recorded; what never happened is the routing after
    # it. Re-running it (mode retry) would put a second implementation on the branch,
    # charge the issue a second time, and skip the role the state's own log already
    # names as next. `dropped` is here because /swarm start on a dropped issue is
    # documented to behave as a resume.
    pre(.status | IN("blocked", "parked", "dropped"); "status is \(.status)")
    | pre(.next == null; "\(.next.key) is already queued")
    | pre(.current != null; "no current dispatch to route on from")
    | .status = "routing" | .blocked = null | .parked = null | .gate = null
  elif $m == "retry" then
    pre(.status | IN("blocked", "parked", "dropped"); "status is \(.status), not blocked/parked/dropped")
    | pre(has_arg("role") or (.current != null); "no current dispatch to retry")
    | (.current.key // null) as $ck | (.current.run_id // null) as $cr
    | (if $ck != null and $cr != null and ((rec($ck; $cr) | .status) == "running") then update_rec($ck; $cr; .status = "superseded" | .finished_at = ts | .superseded_by = "resume") else . end)
    | queue(opt("stage"; .stage); opt("role"; .current.role); "resume")
  elif $m == "finalize" then
    pre(.status == "blocked" and (.blocked.reason == "stalled"); "status is \(.status)\(if .blocked != null then ":" + .blocked.reason else "" end), not blocked:stalled")
    | pre(.current != null; "no current dispatch to finalise")
    # Back to the status the block interrupted, which block.jq recorded in
    # `blocked.from`. `running` alone would wedge the one case that matters: a run
    # whose record is already `finished` stalled while ROUTING. advance.sh answers
    # "already finalised" and exits, reconcile.sh sees `running` and does nothing, so
    # the resume is a silent no-op that clears the labels and can be repeated
    # forever. Restored to `routing`, reconcile.sh's routing branch routes it on.
    | ((.blocked.from // "running") as $from
       | .status = (if $from == "routing" then "routing" else "running" end))
    | .blocked = null
  elif $m == "evidence" then
    pre(.evidence.pending != null; "no pending evidence wait")
    | pre(.status | IN("evidence", "blocked", "parked"); "status is \(.status)")
    | .status = "evidence" | .blocked = null | .parked = null
    | (if $was == "blocked" then .evidence.pending.fired_at = null else . end)
  elif $m == "question" then
    pre(.status == "gate" and .gate.name == "question"; "status is \(.status), not the question gate")
    | .owner_reason = { kind: "answer", by: opt("by"; null), at: ts, text: (opt("note"; "no answer; proceed on stated assumptions") | tostring | .[0:4000]) }
    | queue(opt("stage"; .stage); opt("role"; "analyst"); "answer")
  else error("input: unknown resume mode \($m)") end
| log_event("resume"; opt("by"; null); "\($m) from \($was)")
