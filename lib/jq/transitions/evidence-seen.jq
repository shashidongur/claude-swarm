# evidence-seen — a mapped workflow_run conclusion, recorded at ANY status (G18),
# keyed head / workflow name / event; last writer wins by `at`.
#   --arg head <sha> --arg workflow <name> --arg event pull_request|push|workflow_dispatch|…
#   --arg run_id N --arg conclusion success|failure|cancelled|… [--arg url …] [--arg at ISO]
include "_lib";
state_pre
| (need("head")) as $h | (need("workflow")) as $w | (need("event")) as $e
| (opt("at"; ts)) as $at
| ((.evidence.seen // {})[$h][$w][$e]) as $old
| if ($old != null) and (($old.at // "") > $at) then .
  else
    .evidence.seen[$h][$w][$e] = { run_id: (need("run_id") | toint), conclusion: need("conclusion"), at: $at }
      + (if has_arg("url") then {url: arg("url")} else {} end)
  end
