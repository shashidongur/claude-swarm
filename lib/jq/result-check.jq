# result-check.jq — the shape checks of spec §7.2 over a role's .swarm-run/result.json.
#
#   jq -f lib/jq/result-check.jq [--arg role dev:app] [--arg class write]
#      [--arg issue 7] [--arg stage build] [--arg attempt 1] [--arg owner_repo o/r] result.json
#
# Output: an array of `{check, msg}` — empty when the document is well-formed. `check`
# is "schema" for a shape violation, or the spec's V-number when the rule has one
# (V1 identity, V10 rework target/reason, V11 questions, V12 sub-issues, V13 memory
# paths, V15 triage enums, V16 handles/comment delimiters, V19 url prefix).
# The optional arguments enable the checks that need the brief's values (V1, the class
# rules for `touches`/`head`, the owner/repo part of V19); without them those checks are
# skipped, never failed. The reality checks (paths on disk, head on origin, refs in the
# requirements doc) are lib/sh/validate-result.sh's, not this file's.

def named: $ARGS.named;
def arg($k): if (named | has($k)) and (named[$k] | tostring | length > 0) then named[$k] else null end;

def err($c; $m): {check: $c, msg: $m};

def path_re: "^([A-Za-z0-9_]|\\.[A-Za-z0-9_-])[A-Za-z0-9._-]*(/([A-Za-z0-9_]|\\.[A-Za-z0-9_-])[A-Za-z0-9._-]*)*$";
def is_path: type == "string" and test(path_re);
def is_dirty: type == "string" and test("@[A-Za-z0-9-]|<!--|-->");
def is_int_ge($n): type == "number" and . == floor and . >= $n;
def is_nonempty_str: type == "string" and length > 0;
def stages: ["triage","requirements","design","architecture","build","test","security","release","retro"];
def verdicts: ["pass","rework","blocked","question","duplicate"];
def role_re: "^(triage|analyst|ux|a11y|architect|threat-model|planner|test-writer|dev(:[A-Za-z0-9_-]+)?|code-review(:[A-Za-z0-9_-]+)?|qa|security|compliance|release|retro)$";
def top_keys: ["v","issue","stage","role","attempt","verdict","summary","evidence","artifacts","touches","head","refs","rework_to","reason","questions","hints","subissues","memory","duplicates","triage","not_covered"];
def hint_keys: ["path","area","lanes","walkthrough","redo"];

def base_role: (.role // "" | tostring | split(":")[0]);
def write_roles: ["test-writer","dev","release"];

# one evidence item at index $i
def check_evidence($i):
  if type != "object" then err("schema"; "evidence[\($i)] is not an object")
  else
    (.kind // null) as $k
    | if $k == "command" then
        (if (.cmd | is_nonempty_str) | not then err("schema"; "evidence[\($i)]: kind=command needs a non-empty cmd") else empty end),
        (if has("exit") and ((.exit | is_int_ge(-1)) | not) then err("schema"; "evidence[\($i)]: exit must be an integer") else empty end),
        (if has("result") and (.result | type) != "string" then err("schema"; "evidence[\($i)]: result must be a string") else empty end),
        ((keys - ["kind","cmd","result","exit"]) | if length > 0 then err("schema"; "evidence[\($i)]: unknown fields \(join(", "))") else empty end)
      elif $k == "file" then
        (if (.path | is_path) | not then err("schema"; "evidence[\($i)]: path must match the path grammar (no .., no leading /, no empty segment)") else empty end),
        (if has("line") and ((.line | is_int_ge(1)) | not) then err("schema"; "evidence[\($i)]: line must be a positive integer") else empty end),
        (if has("symbol") and (.symbol | type) != "string" then err("schema"; "evidence[\($i)]: symbol must be a string") else empty end),
        ((keys - ["kind","path","line","symbol"]) | if length > 0 then err("schema"; "evidence[\($i)]: unknown fields \(join(", "))") else empty end)
      elif $k == "url" then
        (if (.url | type) != "string" then err("schema"; "evidence[\($i)]: url must be a string")
         elif (.url | test("^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*/[^\\s@<>]*$")) | not
           then err("V19"; "evidence[\($i)]: url must start with https://github.com/<owner>/<repo>/")
         elif (arg("owner_repo") != null) and ((.url | startswith("https://github.com/\(arg("owner_repo"))/")) | not)
           then err("V19"; "evidence[\($i)]: url must start with https://github.com/\(arg("owner_repo"))/")
         else empty end),
        (if has("note") and (.note | type) != "string" then err("schema"; "evidence[\($i)]: note must be a string") else empty end),
        ((keys - ["kind","url","note"]) | if length > 0 then err("schema"; "evidence[\($i)]: unknown fields \(join(", "))") else empty end)
      elif $k == "artifact" then
        (if (.path | is_path) | not then err("schema"; "evidence[\($i)]: path must match the path grammar") else empty end),
        (if has("note") and (.note | type) != "string" then err("schema"; "evidence[\($i)]: note must be a string") else empty end),
        ((keys - ["kind","path","note"]) | if length > 0 then err("schema"; "evidence[\($i)]: unknown fields \(join(", "))") else empty end)
      else err("schema"; "evidence[\($i)]: kind must be one of command, file, url, artifact")
      end
  end;

def check_path_list($name):
  if has($name) then
    (if (.[$name] | type) != "array" then err("schema"; "\($name) must be an array")
     else (.[$name] | to_entries[] | select(.value | is_path | not) | err("schema"; "\($name)[\(.key)] does not match the path grammar (no .., no leading /, no empty segment)")),
          (if (.[$name] | length) != (.[$name] | unique | length) then err("schema"; "\($name) has duplicate entries") else empty end)
     end)
  else empty end;

def check_subissues:
  if has("subissues") then
    (if (.subissues | type) != "array" or (.subissues | length) == 0 then err("V12"; "subissues must be a non-empty array")
     else .subissues | to_entries[] | .key as $i | .value
       | if type != "object" then err("V12"; "subissues[\($i)] is not an object")
         else
           (if (.lane | type) != "string" or ((.lane | test("^[A-Za-z0-9_-]+$")) | not) then err("V12"; "subissues[\($i)]: lane must be a lane name") else empty end),
           (if (.title | is_nonempty_str | not) or (.title | length) > 80 then err("V12"; "subissues[\($i)]: title must be 1–80 characters") else empty end),
           (if (.body_file | is_path) | not then err("V12"; "subissues[\($i)]: body_file must match the path grammar") else empty end),
           ((keys - ["lane","title","body_file"]) | if length > 0 then err("V12"; "subissues[\($i)]: unknown fields \(join(", "))") else empty end)
         end
     end)
  else empty end;

def memory_path_ok:
  (.kind // "") as $k | (.path // "") as $p
  | ($p | is_path) and
    (if $k == "gotcha" then ($p | test("^gotchas/auto/[a-z0-9-]+\\.md$"))
     elif $k == "adr" then ($p | test("^adrs/[0-9]{4}-[a-z0-9-]+\\.md$"))
     elif $k == "postmortem" then ($p | test("^postmortems/[0-9]+\\.md$"))
     elif $k == "runs" then ($p | test("^runs/[0-9]+\\.json$"))
     else false end);

def check_memory($base):
  if has("memory") then
    (if (.memory | type) != "array" then err("V13"; "memory must be an array")
     else .memory | to_entries[] | .key as $i | .value
       | if type != "object" then err("V13"; "memory[\($i)] is not an object")
         else
           (if ((.kind // "") | IN("gotcha","adr","postmortem","runs")) | not then err("V13"; "memory[\($i)]: kind must be gotcha, adr, postmortem or runs") else empty end),
           (if $base != "retro" and (.kind // "") != "gotcha" then err("V13"; "memory[\($i)]: only the retro may propose \(.kind // "that") entries; other roles propose gotchas") else empty end),
           (if memory_path_ok | not then err("V13"; "memory[\($i)]: path must be postmortems/<N>.md, adrs/<NNNN>-<slug>.md, gotchas/auto/<slug>.md or runs/<N>.json for its kind") else empty end),
           (if (.content_file | is_path) | not then err("V13"; "memory[\($i)]: content_file must match the path grammar") else empty end),
           ((keys - ["kind","path","content_file"]) | if length > 0 then err("V13"; "memory[\($i)]: unknown fields \(join(", "))") else empty end)
         end
     end)
  else empty end;

def check_triage:
  if has("triage") then
    (if (.triage | type) != "object" then err("V15"; "triage must be an object")
     else .triage
       | (if ((.type // "") | IN("bug","feature","chore")) | not then err("V15"; "triage.type must be bug, feature or chore") else empty end),
         (if ((.size // "") | IN("S","M","L","XL")) | not then err("V15"; "triage.size must be S, M, L or XL") else empty end),
         (if (.area | type) != "string" or ((.area | test("^[A-Za-z0-9_-]+$")) | not) then err("V15"; "triage.area must be a lane name or both") else empty end),
         (if ((.prio // "") | IN("P0","P1","P2","P3")) | not then err("V15"; "triage.prio must be P0–P3") else empty end),
         (if ((.path // "") | IN("full","short")) | not then err("V15"; "triage.path must be full or short") else empty end),
         ((keys - ["type","size","area","prio","path"]) | if length > 0 then err("V15"; "triage: unknown fields \(join(", "))") else empty end)
     end)
  else empty end;

def check_hints:
  if has("hints") then
    (if (.hints | type) != "object" then err("schema"; "hints must be an object")
     else .hints
       | ((keys - hint_keys) | if length > 0 then err("schema"; "hints: unknown fields \(join(", "))") else empty end),
         (if has("path") and ((.path | IN("full","short")) | not) then err("schema"; "hints.path must be full or short") else empty end),
         (if has("redo") and ((.redo | IN(stages[])) | not) then err("schema"; "hints.redo must be a stage") else empty end),
         (if has("area") and ((.area | type) != "string" or ((.area | test("^[A-Za-z0-9_-]+$")) | not)) then err("schema"; "hints.area must be a lane name or both") else empty end),
         (if has("lanes") and ((.lanes | type) != "array" or any(.lanes[]; (type != "string") or ((test("^[A-Za-z0-9_-]+$")) | not))) then err("schema"; "hints.lanes must be an array of lane names") else empty end),
         (if has("walkthrough") and (.walkthrough | type) != "boolean" then err("schema"; "hints.walkthrough must be a boolean") else empty end)
     end)
  else empty end;

# V16 over every string in the document, reported by its path
def check_strings:
  paths(type == "string") as $p
  | getpath($p) as $s
  | if ($s | is_dirty) then err("V16"; "\($p | map(tostring) | join(".")) contains a handle (@x) or a comment delimiter (<!-- / -->)") else empty end;

def check_identity:
  (if arg("issue") != null and ((.issue | tostring) != (arg("issue") | tostring)) then err("V1"; "issue \(.issue) does not equal the brief's \(arg("issue"))") else empty end),
  (if arg("stage") != null and (.stage != arg("stage")) then err("V1"; "stage \(.stage) does not equal the brief's \(arg("stage"))") else empty end),
  (if arg("role") != null and (.role != arg("role")) then err("V1"; "role \(.role) does not equal the brief's \(arg("role"))") else empty end),
  (if arg("attempt") != null and ((.attempt | tostring) != (arg("attempt") | tostring)) then err("V1"; "attempt \(.attempt) does not equal the brief's \(arg("attempt"))") else empty end);

def check_all:
  base_role as $base
  | (.verdict // null) as $v
  | (arg("class")) as $class
  | [
      ((keys - top_keys) | if length > 0 then
          (if index("next") != null then err("schema"; "`next` is not a role's field — routing is not the role's business") else empty end),
          err("schema"; "unknown top-level fields: \(join(", "))")
        else empty end),
      (if .v != 2 then err("schema"; "v must be 2") else empty end),
      (if (.issue | is_int_ge(1)) | not then err("schema"; "issue must be a positive integer") else empty end),
      (if ((.stage // "") | IN(stages[])) | not then err("schema"; "stage must be one of \(stages | join(", "))") else empty end),
      (if (.role | type) != "string" or ((.role | test(role_re)) | not) then err("schema"; "role must be a swarm role name (with :lane for dev and code-review)") else empty end),
      (if (.attempt | is_int_ge(1)) | not then err("schema"; "attempt must be a positive integer") else empty end),
      (if ($v | IN(verdicts[])) | not then err("schema"; "verdict must be one of \(verdicts | join(", "))") else empty end),
      (if (.summary | is_nonempty_str) | not then err("schema"; "summary must be a non-empty string")
       elif (.summary | length) > 900 then err("schema"; "summary must be at most 900 characters (\(.summary | length))") else empty end),
      (if has("evidence") and (.evidence | type) != "array" then err("schema"; "evidence must be an array")
       elif has("evidence") then (.evidence | to_entries[] | .key as $i | .value | check_evidence($i)) else empty end),
      (if ($v == "pass" or $v == "rework") and (((.evidence // []) | length) == 0) then err("schema"; "verdict \($v) needs at least one evidence item") else empty end),
      (if ($v | IN("rework","blocked","question","duplicate")) and ((.reason | is_nonempty_str) | not) then err("schema"; "verdict \($v) needs a reason") else empty end),
      (if has("reason") and (.reason | type) != "string" then err("schema"; "reason must be a string") else empty end),
      (if $v == "rework" and ($base | IN("a11y","threat-model") | not) and ((.rework_to | is_nonempty_str) | not) then err("V10"; "verdict rework needs rework_to (except a11y and threat-model, whose target is fixed)") else empty end),
      (if has("rework_to") and ((.rework_to | type) != "string" or ((.rework_to | test("^[a-z][a-z0-9-]*(:[A-Za-z0-9_-]+)?$")) | not)) then err("V10"; "rework_to must be a role name (with :lane)") else empty end),
      (if $v == "rework" and ($base | IN("code-review","qa","security","compliance")) and (((.reason // "") | length) < 20) then err("V10"; "reason must be at least 20 characters on a rework") else empty end),
      (if $v == "duplicate" and $base != "triage" then err("schema"; "duplicate is a triage-only verdict") else empty end),
      (if $v == "duplicate" and (((.duplicates // []) | length) == 0) then err("schema"; "verdict duplicate needs duplicates[]") else empty end),
      (if has("duplicates") then
          (if (.duplicates | type) != "array" or any(.duplicates[]; (is_int_ge(1)) | not) then err("schema"; "duplicates must be an array of issue numbers")
           elif (.duplicates | length) != (.duplicates | unique | length) then err("schema"; "duplicates has repeated entries")
           elif (.issue as $n | any(.duplicates[]; . == $n)) then err("V15"; "duplicates must not name the issue itself")
           else empty end)
        else empty end),
      (if $base != "triage" and (has("triage") or has("duplicates")) then err("schema"; "triage and duplicates are triage-only fields") else empty end),
      (if $base == "triage" and $v == "pass" and (has("triage") | not) then err("V15"; "triage must set the triage block on pass") else empty end),
      check_triage,
      (if $v == "question" and $base != "analyst" then err("schema"; "question is an analyst-only verdict") else empty end),
      (if $base != "analyst" and has("questions") then err("schema"; "questions is an analyst-only field") else empty end),
      (if $v == "question" and (has("questions") | not) then err("V11"; "verdict question needs questions[]") else empty end),
      (if has("questions") then
          (if (.questions | type) != "array" or (.questions | length) < 1 or (.questions | length) > 3 then err("V11"; "questions must hold 1–3 entries")
           else .questions | to_entries[] | .key as $i | .value
             | (if type != "object" then err("V11"; "questions[\($i)] is not an object")
                else
                  (if ((.to // "") | IN("reporter","approver")) | not then err("V11"; "questions[\($i)].to must be reporter or approver") else empty end),
                  (if (.q | is_nonempty_str | not) or (.q | length) < 15 then err("V11"; "questions[\($i)].q must be at least 15 characters") else empty end),
                  ((keys - ["to","q"]) | if length > 0 then err("V11"; "questions[\($i)]: unknown fields \(join(", "))") else empty end)
                end)
           end)
        else empty end),
      (if $base != "planner" and has("subissues") then err("schema"; "subissues is a planner-only field") else empty end),
      check_subissues,
      check_memory($base),
      check_path_list("artifacts"),
      check_path_list("touches"),
      (if has("head") and ((.head | type) != "string" or ((.head | test("^[0-9a-f]{40}$")) | not)) then err("schema"; "head must be a full 40-hex sha") else empty end),
      (if $class == "read" and (((.touches // []) | length) > 0) then err("schema"; "a read-class role may not set touches") else empty end),
      (if ($class == "write" or ($class == null and ($base | IN(write_roles[])))) and $v == "pass" and (has("head") | not) then err("schema"; "a write-class role must set head to the pushed sha on pass") else empty end),
      (if has("refs") then
          (if (.refs | type) != "array" or any(.refs[]; (type != "string") or ((test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) | not)) then err("schema"; "refs must be an array of requirement/AC ids")
           elif (.refs | length) != (.refs | unique | length) then err("schema"; "refs has duplicate entries") else empty end)
        else empty end),
      check_hints,
      (if has("not_covered") and ((.not_covered | type) != "array" or any(.not_covered[]; (is_nonempty_str) | not)) then err("schema"; "not_covered must be an array of non-empty strings") else empty end),
      check_strings,
      check_identity
    ];

if type != "object" then [err("schema"; "result.json must be a JSON object")]
else check_all end
