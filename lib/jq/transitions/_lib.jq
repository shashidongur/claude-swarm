# _lib.jq — helpers shared by every transition (`include "_lib";`, loaded by
# state.sh with `jq -L lib/jq/transitions`). Not a transition itself: state.sh
# refuses transition names that start with "_".
#
# Every transition receives at least `--arg now <ISO-8601 UTC>` and
# `--arg run_id <id>` from state.sh; anything else is named at the top of its file.
# A precondition failure is `error("precondition: …")` (jq exits 5 — state.sh maps
# it to "state moved on", exit 5); a missing input is `error("input: …")`.

def arg($k): $ARGS.named[$k];
def has_arg($k): ($ARGS.named | has($k)) and ($ARGS.named[$k] != null) and (($ARGS.named[$k] | tostring) != "");
def need($k): if has_arg($k) then arg($k) else error("input: --arg \($k) is required") end;
def opt($k; $d): if has_arg($k) then arg($k) else $d end;
def toint: if type == "number" then floor else (tostring | tonumber | floor) end;
def opt_int($k; $d): if has_arg($k) then (arg($k) | toint) else $d end;
def ts: need("now");
def run_id: opt_int("run_id"; 0);
def epoch: fromdateiso8601;

def pre(cond; msg): if cond then . else error("precondition: " + msg) end;
def is_state: (type == "object") and (.v == 2) and ((.issue | type) == "number");
# `seq` counts transitions and only ever goes up. The signature proves a document was
# written by us; it cannot prove it is the LATEST one we wrote, so restoring an older
# signed document to the state branch would otherwise replay cleanly — un-consuming
# gate approvals, resetting the cost total, rewinding attempt counters. seq makes such
# a rewind visible: state.sh refuses a re-read that goes backwards, the rendered state
# comment carries it, and G29(d) no longer excludes the state branch from the activity
# check. (A signed document restored while nothing else is running still verifies —
# closing that needs a counter stored off the branch.)
def state_pre: pre(is_state; "not a v2 state document") | .seq = ((.seq // 0) + 1);

def stage_order: ["triage", "requirements", "design", "architecture", "build", "test", "security", "release", "retro"];
def stage_index($s): (stage_order | index($s)) // 99;
def lane_of($role): ($role | split(":") | if length > 1 then .[1] else null end);
def attempt_of_key($k): ($k | split(":") | last | tonumber);

# log — the last 50 human/machine events
def log_event($ev; $by; $note):
  .log = (((.log // []) + [
    {at: ts, event: $ev}
    + (if ($by // "") != "" then {by: $by} else {} end)
    + (if ($note // "") != "" then {note: ($note | tostring | .[0:500])} else {} end)
  ]) | .[-50:]);
def log_event($ev): log_event($ev; opt("by"; null); opt("note"; null));

# dispatches[] is append-only and capped at 60: the oldest records are dropped and
# counted in totals.folded (their cost/minutes are already in the running totals).
# What must NOT be lost with them is which roles finished with a pass: V14 builds the
# "every recorded artifact is on head" census from that, so a folded record would
# quietly stop being checked — exactly on the long, rework-heavy issues where the
# release check matters most. Their {role, attempt} pairs are kept instead; the list is
# bounded by the number of role-attempts on the path, not by the number of dispatches.
def cap_dispatches:
  if ((.dispatches // []) | length) > 60 then
    (((.dispatches | length) - 60)) as $n
    | .totals.folded = ((.totals.folded // 0) + $n)
    | .totals.folded_cost_usd = ((.totals.folded_cost_usd // 0) + ([.dispatches[:$n][] | .cost_usd // 0] | add))
    | .totals.folded_passes = (((.totals.folded_passes // [])
        + [.dispatches[:$n][] | select(.status == "finished" and .verdict == "pass") | {role, attempt: (.attempt // 1)}])
        | unique)
    | .dispatches = .dispatches[$n:]
  else . end;

def rec_index($key; $rid): ((.dispatches // []) | map(.key == $key and .run_id == $rid) | index(true));
def rec($key; $rid): (rec_index($key; $rid)) as $i | if $i == null then null else .dispatches[$i] end;
def update_rec($key; $rid; f): (rec_index($key; $rid)) as $i | if $i == null then . else .dispatches[$i] |= f end;

def new_key($stage; $role): "\(.issue):\($stage):\($role):\(((.stages[$stage].attempts // {})[$role] // 0) + 1)";

# routing facts a caller may fold into the same CAS as the routing decision
# (--arg done_stage, --arg done_lane, --argjson triage, --arg path, --arg path_source,
#  --argjson lanes, --argjson subissues, --arg head, --argjson pr, --arg branch,
#  --arg stage — entering the next stage, e.g. for an evidence wait keyed on it)
def apply_facts:
  (if has_arg("done_stage") then
      (arg("done_stage")) as $s
      | .stages[$s].status = "done"
      | .stages[$s].lanes = ((.stages[$s].lanes // {}) | with_entries(.value = "done"))
    else . end)
  | (if has_arg("done_lane") then .stages[.stage].lanes[arg("done_lane")] = "done" else . end)
  | (if has_arg("triage") then .triage = (arg("triage") | if type == "string" then fromjson else . end) else . end)
  | (if has_arg("path") then
      .path = arg("path") | .path_source = opt("path_source"; "triage")
      | (if .path == "short" then
           .stages.design.status = (if .stages.design.status == "pending" then "skipped" else .stages.design.status end)
           | .stages.architecture.status = (if .stages.architecture.status == "pending" then "skipped" else .stages.architecture.status end)
         else
           .stages.design.status = (if .stages.design.status == "skipped" then "pending" else .stages.design.status end)
           | .stages.architecture.status = (if .stages.architecture.status == "skipped" then "pending" else .stages.architecture.status end)
         end)
    else . end)
  | (if has_arg("lanes") then
      (arg("lanes") | if type == "string" then fromjson else . end) as $l
      | .lanes = $l
      | .stages.build.lanes = (reduce $l[] as $x ((.stages.build.lanes // {}); .[$x] = (.[$x] // "pending")))
    else . end)
  | (if has_arg("subissues") then .subissues = ((.subissues // {}) + (arg("subissues") | if type == "string" then fromjson else . end)) else . end)
  | (if has_arg("head") then .head = arg("head") else . end)
  | (if has_arg("branch") then .branch = arg("branch") else . end)
  | (if has_arg("stage") and ((.stages // {}) | has(arg("stage"))) then .stage = arg("stage") else . end)
  | (if has_arg("pr") then .pr = (arg("pr") | toint) else . end);

# queue($stage; $role; $reason; $not_before): the one way a new dispatch is queued.
# Attempt = the monotonic counter + 1 (never the number of records); the key is new
# by construction, and a record that already carries it is a key-reuse error.
def queue($stage; $role; $reason; $not_before):
  pre((.stages // {}) | has($stage); "unknown stage \($stage)")
  | new_key($stage; $role) as $k
  | (((.stages[$stage].attempts // {})[$role] // 0) + 1) as $a
  | pre(([(.dispatches // [])[] | select(.key == $k)] | length) == 0; "key reuse: \($k) already has a dispatch record")
  | .stages[$stage].attempts[$role] = $a
  | .stages[$stage].status = "running"
  | (lane_of($role)) as $lane
  | (if $lane != null then .stages[$stage].lanes[$lane] = "running" else . end)
  | .stage = $stage
  | .status = "queued"
  | .next = {stage: $stage, role: $role, key: $k, fired_at: null, fired_by: null, fired_run_id: null, not_before: $not_before, reason: $reason}
  | .gate = null
  | .blocked = null
  | .parked = null
  | .evidence.pending = null
  | .dispatches = ((.dispatches // []) + [{
      key: $k, run_id: 0, stage: $stage, role: $role, attempt: $a, at: ts,
      claimed_at: null, finished_at: null, status: "queued", verdict: null,
      model_requested: opt("model"; null), model_actual: null,
      cost_usd: 0, turns: 0, duration_s: 0, job_minutes: 0, overhead_minutes: 0, retry: 0, critic: null,
      base_sha: null, head: null, artifact: null, handoff: null, died_reason: null,
      validation: null, last_text: null, reason: $reason }])
  | cap_dispatches;
def queue($stage; $role; $reason): queue($stage; $role; $reason; null);

# totals from a finished/died/invalid run's stats object
def add_totals($st):
  .totals.cost_usd = (((.totals.cost_usd // 0) + ($st.cost_usd // 0)) * 10000 | round / 10000)
  | .totals.turns = ((.totals.turns // 0) + ($st.turns // 0))
  | .totals.role_seconds = ((.totals.role_seconds // 0) + ($st.duration_s // 0 | floor))
  | .totals.runner_minutes = ((.totals.runner_minutes // 0) + ($st.job_minutes // 0 | floor))
  | .totals.overhead_minutes = ((.totals.overhead_minutes // 0) + ($st.overhead_minutes // 0 | floor))
  | (if ($st.model_requested != null) and ($st.model_actual != null) and ($st.model_requested != $st.model_actual)
     then .models.honoured = false else . end);

def stats_arg: (opt("stats"; "{}") | if type == "string" then fromjson else . end);

# the record fields every terminal status writes
def record_terminal($st; $status):
  # overhead_minutes rides on the record as well as in totals: state.sh month-totals
  # attributes minutes to the month a dispatch ran in, and without it the overhead half
  # of the figure the monthly brake reads would always be zero.
  . + ($st | with_entries(select(.key | IN("verdict", "model_requested", "model_actual", "cost_usd", "turns", "duration_s",
                                                "job_minutes", "overhead_minutes", "retry", "critic", "head", "artifact", "handoff",
                                                "died_reason", "validation", "last_text", "run_attempt", "base_sha"))))
  | .status = $status
  | .finished_at = ts
  | .last_text = (if .last_text == null then null else (.last_text | tostring | .[0:500]) end);
