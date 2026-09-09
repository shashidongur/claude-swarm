# render-state.jq — the state comment (spec §4.1): a header humans read, a checklist,
# the branch line, and the signed document inside <details>, ending in the state marker.
#
#   jq -r [--arg cap 75] [--arg artifacts_dir docs/swarm] [--arg swarm_ref v2]
#         [--arg state_branch swarm/state] [--arg run_url …] [--arg at 2026-09-06T14:41:39Z]
#         -f lib/jq/render-state.jq issues/7.json > comment.md
#
# Input: the state document. Output: a stream of three values — the text above the
# JSON block, the sanitised document (jq pretty-prints it), and the closing lines with
# the marker — so `-r` renders the whole comment. Every string inside the document is
# sanitised (dispatch records carry role text such as `last_text`), so a role can never
# plant a marker or a mention through the state comment. The marker is the only
# `<!--` in the output and is written here, not by a role.

def sanitize:
  if type != "string" then .
  else gsub("<!--"; "<!-​-")
     | gsub("-->"; "-​->")
     | gsub("@(?<c>[A-Za-z0-9-])"; "@​\(.c)")
  end;
def sanitize_all: walk(if type == "string" then sanitize else . end);

def arg($k): if ($ARGS.named | has($k)) and (($ARGS.named[$k] | tostring | length) > 0) then $ARGS.named[$k] else null end;
def money: ((. // 0) * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)";
def sha7: if type == "string" and length >= 7 then .[0:7] else . end;
def stage_order: ["triage","requirements","design","architecture","build","test","security","release","retro"];
def stage_roles($stage):
  if $stage == "triage" then ["triage"]
  elif $stage == "requirements" then ["analyst"]
  elif $stage == "design" then ["ux","a11y"]
  elif $stage == "architecture" then ["architect","threat-model"]
  elif $stage == "build" then ((if .path == "short" then [] else ["planner"] end) + ["test-writer"] + [(.lanes // [])[] | "dev:\(.)", "code-review:\(.)"])
  elif $stage == "test" then ["qa"]
  elif $stage == "security" then ["security","compliance"]
  elif $stage == "release" then ["release"]
  elif $stage == "retro" then ["retro"]
  else ((.stages[$stage].attempts // {}) | keys_unsorted) end;

def dispatches_for($stage): [(.dispatches // [])[] | select(.stage == $stage)];

# one role's mark on its stage line
def role_mark($stage; $role):
  (.current // {}) as $cur
  | (dispatches_for($stage) | map(select(.role == $role)) | last) as $last
  | ((.stages[$stage].attempts // {}) | has($role)) as $tried
  | (($role | split(":") | .[1] // "") as $lane | ((.stages[$stage].lanes // {})[$lane] // "")) as $lane_status
  | if .status == "running" and .stage == $stage and $cur.role == $role then "**\($role) ⏳**"
    elif $last != null and $last.status == "running" then "**\($role) ⏳**"
    elif $last != null and $last.status == "finished" and $last.verdict == "pass" then "\($role) ✓"
    elif $last != null and $last.status == "finished" and $last.verdict == "rework" then "\($role) 🔄"
    elif $last != null and $last.status == "finished" and $last.verdict == "question" then "\($role) ❓"
    elif $last != null and $last.status == "finished" and $last.verdict == "blocked" then "\($role) 🚧"
    elif $last != null and $last.status == "died" then "\($role) 💀"
    elif $last != null and $last.status == "invalid" then "\($role) 🚧"
    elif $lane_status == "done" then "\($role) ✓"
    elif $tried and (.stages[$stage].status == "done") then "\($role) ✓"
    elif $tried then "\($role) ✓"
    else $role end;

def stage_detail($stage):
  (.stages[$stage] // {}) as $st
  | if $st.status == "skipped" then "skipped (short path)"
    elif $st.status == "skipped_by_owner" then "skipped by owner"
    else
      ([ (if $stage == "triage" and (.triage | type) == "object" then
            "short? \(if .path == "short" then "yes" else "no" end) (\(.triage.type // "?"), \(.triage.size // "?"), \(.triage.area // "?"))"
          else empty end),
         (if $stage == "triage" then
            (dispatches_for("triage") | last) as $t
            | if $t != null then ($t.model_actual // $t.model_requested // empty), ("$" + ($t.cost_usd | money)) else empty end
          else empty end),
         (if $stage != "triage" then (stage_roles($stage)[] as $r | role_mark($stage; $r)) else empty end),
         (if $stage == "build" and .pr != null then "PR #\(.pr)" else empty end),
         (if ($st.approved | type) == "object" then "approved by \($st.approved.by // "?") \($st.approved.at // "")" else empty end),
         (if ($st.critic | type) == "object" and $st.critic.score != null then "critic \($st.critic.score)" else empty end)
       ] | map(select(. != null and . != "")) | join(" · "))
    end;

def stage_box($stage):
  (.stages[$stage].status // "pending") as $s
  | if $s == "done" or $s == "skipped" or $s == "skipped_by_owner" then "[x]" else "[ ]" end;

def checklist:
  [ stage_order[] as $st | select(.stages | has($st))
    | { name: $st, box: stage_box($st),
        pending: ((.stages[$st].status // "pending") == "pending" and $st != .stage),
        detail: stage_detail($st) } ]
  | reduce .[] as $e ([];
      if $e.pending and (length > 0) and (.[-1] | type) == "object" then .[-1].names += [$e.name]
      elif $e.pending then . + [{names: [$e.name]}]
      else . + ["- \($e.box) \($e.name)\(if $e.detail == "" then "" else " — " + $e.detail end)"] end)
  | map(if type == "object" then "- " + (.names | map("[ ] " + .) | join(" · ")) else . end);

def status_phrase:
  (.status // "?") as $s
  | if $s == "running" then "running `\(.current.role // "?")` (attempt \(.current.attempt // "?"))"
    elif $s == "routing" then "routing"
    elif $s == "queued" then "queued — fired \(.next.fired_at // "not yet"), run \(.next.fired_run_id // "not yet started")\(if .next.not_before != null then " · not before \(.next.not_before)" else "" end)"
    elif $s == "evidence" then "waiting for evidence `\(.evidence.pending.workflow // "?")` on \(.evidence.pending.head // .head | sha7 // "?")"
    elif $s == "gate" then "gate `\(.gate.name // "?")` since \(.gate.since // "?")"
    elif $s == "blocked" then "blocked:\(.blocked.reason // "?")"
    else $s end;

def header:
  [ "🧭 **swarm**",
    (.stage // "?"),
    status_phrase,
    "$" + (.totals.cost_usd | money),
    "\(.totals.runner_minutes // 0) min runner (+\(.totals.overhead_minutes // 0) overhead)",
    "rework \(.rework.spent // 0)/\(.rework.budget // 0)",
    (if arg("cap") != null then "cap $\(arg("cap"))" else empty end)
  ] | join(" · ");

def branch_line:
  [ (if .branch != null then "Branch `\(.branch)`" else empty end),
    (if .head != null then "head `\(.head | sha7)`" else empty end),
    (if .pr != null then "PR #\(.pr)" else empty end),
    (if arg("artifacts_dir") != null then "artifacts `\(arg("artifacts_dir"))/\(.issue)/`" else empty end),
    "state `\(arg("state_branch") // "swarm/state"):issues/\(.issue).json`",
    (if .swarm_sha != null then "swarm `\(arg("swarm_ref") // "v2")@\(.swarm_sha | sha7)`" else empty end)
  ] | join(" · ");

def run_line:
  if arg("run_url") != null then ["Last run: \(arg("run_url"))"]
  elif (.current.run_id // 0) != 0 and .repo != null then ["Last run: https://github.com/\(.repo)/actions/runs/\(.current.run_id)"]
  elif (.next.fired_run_id // 0) != 0 and .repo != null then ["Last run: https://github.com/\(.repo)/actions/runs/\(.next.fired_run_id)"]
  else [] end;

def notes:
  [ (if .merged_at != null then "Merged \(.merged_at) by \(.merged_by // "?")\(if .merged_pr != null then " (PR #\(.merged_pr))" else "" end)" else empty end),
    (if .status == "blocked" and ((.blocked.detail // "") | length) > 0 then "🚧 blocked:\(.blocked.reason // "?") — \(.blocked.detail | sanitize | .[0:300])" else empty end),
    (if .models.honoured == false then "⚠️ model map not honoured — review is by instance, not by model" else empty end),
    (if .flags.hands_off == true then "🛑 hands-off — the machine ignores this issue until the label is removed" else empty end)
  ];

def marker: "<!-- swarm: v2 | kind=state | issue=\(.issue) | at=\(arg("at") // (now | todateiso8601)) -->";

if type != "object" then error("render-state: the input is not a state document")
else
  ([header] + checklist + [""] + [branch_line] + run_line + notes
   + ["", "<details><summary>state (machine)</summary>", "", "```json"] | join("\n")),
  sanitize_all,
  ("```\n</details>\n" + marker)
end
