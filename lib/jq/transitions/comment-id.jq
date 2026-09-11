# comment-id — records the id of a comment the dispatcher posted, after the write
# that made it necessary (working comment after the claim, gate comment, state comment…).
#   --arg target current|gate|state|blocked|questions|next --arg comment_id N [--arg key K]
include "_lib";
state_pre
| (need("target")) as $t
| (need("comment_id") | toint) as $id
| if $t == "current" then
    pre(.current != null and ((has_arg("key") | not) or .current.key == arg("key")); "current is \(.current.key // "-"), not \(opt("key"; ""))")
    | .current.comment_id = $id
    | update_rec(.current.key; .current.run_id; .comment_id = $id)
  elif $t == "gate" then pre(.gate != null; "no gate") | .gate.comment_id = $id
  elif $t == "state" then .state_comment_id = $id
  elif $t == "blocked" then pre(.blocked != null; "not blocked") | .blocked.comment_id = $id
  elif $t == "questions" then .questions.comment_id = $id
  elif $t == "next" then pre(.next != null; "no next") | .next.comment_id = $id
  else error("input: unknown comment target \($t)") end
