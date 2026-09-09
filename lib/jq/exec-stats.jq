# exec-stats.jq — what advance records from an action execution file (spec §11.5).
#
# Input: the execution file's messages as one array (lib/sh/exec-stats.sh slurps an
# array file or a JSONL file into that shape and answers `{present: false}` itself when
# the file is absent or unparsable). Output, one object:
#
#   present            true (the wrapper emits {present:false} otherwise)
#   has_result         a `result` message was found
#   total_cost_usd, num_turns, duration_ms, duration_s   from the result message (null when absent)
#   models[]           modelUsage keys, sorted;  model_actual = the keys joined by "+" (null when none)
#   permission_denials       count;  permission_denials_list  ≤ 10 short descriptions
#   terminal_reason    the result's terminal_reason, else derived from its subtype
#                      (success | max-turns | error | budget | <subtype>)
#   is_error           the result's is_error
#   last_text          the last assistant message's text, ≤ 500 characters
#   wrote_paths[]      file_path of every Write tool_use (the critic acceptance of §8.1)
#   edited_paths[]     file_path of every Edit / MultiEdit / NotebookEdit tool_use
#   bash_commands[]    the command of every Bash tool_use (V4 looks for cmd here)
#   messages           how many messages were read
#
# Strings are not redacted here — the wrapper pipes the whole result through redact.

def msgs: if type == "array" then . elif type == "object" then [.] else [] end;

def content:
  (.message.content // .content // [])
  | if type == "array" then .
    elif type == "string" then [{type: "text", text: .}]
    else [] end;

def short($n): tostring | .[0:$n];

def subtype_reason:
  {"success": "success", "error_max_turns": "max-turns", "error_during_execution": "error",
   "error_max_budget_usd": "budget"}[.] // .;

(msgs | map(select(type == "object"))) as $m
| ($m | map(select(.type == "result")) | last) as $r
| ($m | map(select(.type == "assistant"))) as $a
| ($a | map(content[] | select(.type == "tool_use"))) as $tools
| ($a
   | map(content | map(select(.type == "text") | .text // "") | join("\n"))
   | map(select(length > 0)) | last // "") as $text
| ($r.modelUsage // {} | keys | sort) as $models
| {
    present: true,
    has_result: ($r != null),
    total_cost_usd: ($r.total_cost_usd // null),
    num_turns: ($r.num_turns // null),
    duration_ms: ($r.duration_ms // null),
    duration_s: (if $r.duration_ms == null then null else ($r.duration_ms / 1000 | floor) end),
    models: $models,
    model_actual: (if ($models | length) == 0 then null else ($models | join("+")) end),
    permission_denials: (($r.permission_denials // []) | length),
    permission_denials_list: (($r.permission_denials // [])
      | map("\(.tool_name // "?"): \((.tool_input.file_path // .tool_input.command // "") | short(120))")
      | .[0:10]),
    terminal_reason: ($r.terminal_reason // (if $r.subtype == null then null else ($r.subtype | subtype_reason) end)),
    is_error: ($r.is_error // false),
    last_text: ($text | short(500)),
    wrote_paths: ($tools | map(select(.name == "Write") | .input.file_path // empty) | unique),
    edited_paths: ($tools | map(select(.name == "Edit" or .name == "MultiEdit" or .name == "NotebookEdit") | (.input.file_path // .input.notebook_path) // empty) | unique),
    bash_commands: ($tools | map(select(.name == "Bash") | .input.command // empty)),
    messages: ($m | length)
  }
