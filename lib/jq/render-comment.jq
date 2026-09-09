# render-comment.jq — the stage comment advance leaves behind (spec §11.2).
#
#   jq -r [--arg repo o/r] -f lib/jq/render-comment.jq input.json > comment.md
#
# Input, one object built by advance (every field optional except role and verdict):
#   emoji, role, verdict (working|pass|rework|blocked|question|duplicate|died|superseded|invalid),
#   model, cost_usd, turns, duration_s, job_minutes, rework_spent, rework_budget,
#   summary                  result.json's summary (≤ 900 chars kept)
#   evidence[]               result.json's evidence items, rendered in code spans; a url is
#                            kept only when it starts with https://github.com/<repo>/
#   artifacts[]              "review-app-a1.md" or {path, status: landed|staged|uploaded}
#   head, pr, audit          the head sha, the PR number, the audit artifact name
#   not_covered[], next      free text; the successor (role, gate, stage or a phrase)
#   warnings[]               ⚠ lines (model map, critic error, evidence skipped …)
#   errors[]                 validator errors {check, msg} — rendered when present
#   permission_denials[]     short strings from exec-stats
#   marker                   the marker line built by common.sh `marker` — verbatim
# Everything but the marker passes through sanitize, and evidence text sits in code
# spans, so nothing a role wrote can become a marker or a mention. The layout matches
# lib/templates/stage.tmpl line for line.

def sanitize:
  if type != "string" then .
  else gsub("<!--"; "<!-​-")
     | gsub("-->"; "-​->")
     | gsub("@(?<c>[A-Za-z0-9-])"; "@​\(.c)")
  end;

def arg($k): if ($ARGS.named | has($k)) and (($ARGS.named[$k] | tostring | length) > 0) then $ARGS.named[$k] else null end;
def money: ((. // 0) * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)";
def sha7: if type == "string" and length >= 7 then .[0:7] else . end;
def dur: if . == null then null else (floor) as $t | "\($t / 60 | floor)m\(($t % 60) | tostring | if length < 2 then "0" + . else . end)s" end;
def span: tostring | sanitize | gsub("`"; "'") | gsub("[\r\n]+"; " ") | "`" + . + "`";
def line: tostring | sanitize | gsub("[\r\n]+"; " ");

def verdict_emoji:
  {working: "⏳", running: "⏳", pass: "✅", rework: "🔄", blocked: "🚧", question: "❓",
   duplicate: "🔁", died: "💀", superseded: "⛔", invalid: "🚧", parked: "⏸️", requeued: "⏳"}[.] // "·";
def verdict_word:
  {working: "running", invalid: "invalid output"}[.] // .;

def header:
  [ "\(.emoji // "🧭") **\(.role // "?" | line)**",
    "\(.verdict // "?" | verdict_emoji) \(.verdict // "?" | verdict_word)",
    (if .model != null then (.model | line) else empty end),
    (if .cost_usd != null then "$" + (.cost_usd | money) else empty end),
    (if .turns != null then "\(.turns) turns" else empty end),
    (if .duration_s != null then (.duration_s | dur) else empty end),
    (if .job_minutes != null then "\(.job_minutes) job-min" else empty end),
    (if .rework_spent != null and .rework_budget != null then "rework \(.rework_spent)/\(.rework_budget)" else empty end)
  ] | join(" · ");

def evidence_line:
  if type != "object" then empty
  elif .kind == "command" then
    "- \(.cmd // "" | span)"
    + (if .result != null then " → \(.result | span)" else "" end)
    + (if .exit != null then " (exit \(.exit))" else "" end)
  elif .kind == "file" then
    "- \("\(.path // "")\(if .line != null then ":\(.line)" else "" end)" | span)"
    + (if .symbol != null then " \(.symbol | span)" else "" end)
  elif .kind == "url" then
    (.url // "") as $u
    | if ($u | startswith("https://github.com/" + (arg("repo") // "") + (if arg("repo") != null then "/" else "" end))) and ($u | test("^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*/[^\\s@<>]*$"))
      then "- \($u | line)" + (if .note != null then " — \(.note | line)" else "" end)
      else empty end
  elif .kind == "artifact" then
    "- artifact \(.path // "" | span)" + (if .note != null then " — \(.note | line)" else "" end)
  else empty end;

def artifact_item:
  if type == "string" then (. | line)
  elif type == "object" then
    (.path // .file // "?" | line)
    + (if .status == "staged" then " (staged, lands with the next push)"
       elif .status == "uploaded" then " (uploaded as an artifact — still pending)"
       else "" end)
  else empty end;

def artifacts_line:
  [ (if ((.artifacts // []) | length) > 0 then "Artifacts: " + ([.artifacts[] | artifact_item] | join(" · ")) else empty end),
    (if .head != null then "head \(.head | sha7 | line)" else empty end),
    (if .pr != null then "PR #\(.pr)" else empty end),
    (if .audit != null then "audit \(.audit | line)" else empty end)
  ] | if length == 0 then empty else join(" · ") end;

def body:
  [ header,
    "",
    # One paragraph, never lines of its own: the summary is role-written text landing
    # inside a comment the dispatcher signs. Markers and mentions are already
    # neutralised by sanitize; collapsing newlines stops it drawing a convincing fake
    # gate block with a `/swarm approve` instruction in it.
    (if .summary != null then (.summary | tostring | .[0:900] | line), "" else empty end),
    ((.warnings // [])[] | "⚠️ \(. | line)"),
    (if ((.errors // []) | length) > 0 then
       "Validation errors", ((.errors[] | "- \(.check // "?" | span) \(.msg // "" | line)")), ""
     else empty end),
    (if ((.permission_denials // []) | length) > 0 then
       "Permission denials: \(.permission_denials | length)", ((.permission_denials[] | "- \(. | span)")), ""
     else empty end),
    (if ((.evidence // []) | length) > 0 then "Evidence", (.evidence[] | evidence_line), "" else empty end),
    artifacts_line,
    (if ((.not_covered // []) | length) > 0 then "Not covered: " + ([.not_covered[] | line] | join(" · ")) else empty end),
    (if .next != null then "Next: \(.next | line)" else empty end),
    (if .marker != null then .marker else empty end)
  ];

if type != "object" then error("render-comment: the input is not an object")
else body | join("\n") end
