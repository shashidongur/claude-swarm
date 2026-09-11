# next-fired — records the verified run of a fire. A conditional no-op: if next.key
# matches it sets next.fired_run_id; else if current.key matches (the run already
# claimed the dispatch) it sets current.fired_run_id when unset; otherwise nothing.
# It never fails a precondition beyond "this is a state document".
#   --arg key K --arg run_id <verified run id>
include "_lib";
state_pre
| (need("key")) as $k
| (need("run_id") | toint) as $rid
| if (.next != null) and (.next.key == $k) then
    .next.fired_run_id = $rid
    | update_rec($k; 0; .fired_run_id = $rid)
  elif (.current != null) and (.current.key == $k) and ((.current.fired_run_id // null) == null) then
    .current.fired_run_id = $rid
  else . end
