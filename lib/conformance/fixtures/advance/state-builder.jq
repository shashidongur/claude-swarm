# state-builder.jq — builds a v2 state document for an advance case from a key
# (jq -n; the scenario replaces the placeholders @BASE / @HEAD with real shas).
#
#   jq -n --arg key 7:build:dev:app:1 --arg status running --arg path full --arg pr 9
#         --arg lanes '["api","app"]' --arg now … --arg run_id 424242 --arg comment_id 101
#         --slurpfile pipeline pipeline.json -f state-builder.jq
#
# The stages before the key's stage are done (lanes done), the key's stage is running
# with the key's role as the current dispatch (a `running` record), later stages are
# pending (design/architecture skipped on the short path). `pr` empty → null.
def stage_order: ["triage","requirements","design","architecture","build","test","security","release","retro"];
def arg($k): $ARGS.named[$k];
($ARGS.named.key | split(":")) as $kp
| ($kp[1]) as $stage
| ($kp[2:-1] | join(":")) as $role
| ($kp[-1] | tonumber) as $attempt
| ($role | split(":")[0]) as $base
| ($role | split(":") | .[1] // null) as $lane
| (stage_order | index($stage)) as $si
| (arg("lanes") | fromjson) as $lanes
| ($lanes | index($lane // "")) as $li
| ($pipeline[0] | [.stages[].roles[] | select(.name == $base)] | first | .tier // "default") as $tier
| ($pipeline[0].models.tiers[$tier]) as $model
| (arg("now")) as $now
| (arg("run_id") | tonumber) as $rid
| (arg("status")) as $status
| {
    v: 2, issue: 7, repo: "o/r", created_at: "2026-09-06T09:58:12Z",
    swarm_sha: "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d", pipeline_sha: "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d", config_sha: "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d",
    state_comment_id: 1,
    path: arg("path"), path_source: "triage",
    triage: (if $si > 0 then {type: "feature", size: "M", area: "both", prio: "P2", duplicates: []} else null end),
    lanes: (if $si >= 4 then $lanes else [] end),
    stage: $stage, status: $status,
    current: { role: $role, attempt: $attempt, key: arg("key"), run_id: $rid, run_attempt: 1, comment_id: (arg("comment_id") | tonumber),
               started_at: $now, claimed_at: $now, base_sha: "@BASE", activity_from: $now, fired_run_id: null },
    next: null, gate: null,
    evidence: { pending: null, seen: {}, fires: {} },
    branch: (if $si > 0 then "claude/issue-7-live-session-capacity" else null end),
    head: (if arg("pr") == "" then null else "@HEAD" end),
    pr: (if arg("pr") == "" then null else (arg("pr") | tonumber) end),
    merged_at: null, merged_pr: null, merge_sha: null, merged_by: null,
    subissues: (if $si >= 4 then {api: 12, app: 13, flat: false} else {flat: false} end),
    pending_artifacts: [],
    rework: { spent: 0, budget: 5, reset_at: null, log: [] },
    questions: { rounds: 0, max: 2, comment_id: null },
    stages: ((reduce (stage_order | to_entries[]) as $e ({};
      .[$e.value] = (
        { status: (if $e.key < $si then "done" elif $e.key == $si then "running" else "pending" end), attempts: {} }
        + (if $e.value == "build" then
             { lanes: (reduce ($lanes | to_entries[]) as $l ({};
                 .[$l.value] = (if $e.key < $si then "done"
                                elif $e.key == $si and $li != null and $l.key < $li then "done"
                                elif $e.key == $si and $li != null and $l.key == $li then "running"
                                else "pending" end))) }
           else {} end))))
      | ($pipeline[0].stages | map({name, roles: [.roles[] | {name, per_lane}]})) as $ps
      | reduce ($ps | to_entries[]) as $se (.;
          ($se.value.roles) as $roles
          | ($roles | map(.per_lane == true) | index(true)) as $fl
          | (if $fl == null then ($roles | map(.name))
             else ($roles[:$fl] | map(.name)) + [ $lanes[] as $l | $roles[$fl:][] | select(.per_lane == true) | "\(.name):\($l)" ] + ($roles[$fl:] | map(select(.per_lane != true)) | map(.name)) end) as $tokens
          | ($tokens | index($role)) as $ri
          | reduce ($tokens | to_entries[]) as $t (.;
              if $se.key < $si or ($se.key == $si and $ri != null and $t.key < $ri) then .[$se.value.name].attempts[$t.value] = 1 else . end))
      | .[$stage].attempts[$role] = $attempt
      | (if arg("path") == "short" then .design.status = "skipped" | .architecture.status = "skipped" else . end)),
    dispatches: [ { key: arg("key"), run_id: $rid, stage: $stage, role: $role, attempt: $attempt, run_attempt: 1, at: $now, claimed_at: $now,
                    finished_at: null, status: "running", verdict: null, model_requested: $model, model_actual: null,
                    cost_usd: 0, turns: 0, duration_s: 0, job_minutes: 0, retry: 0, critic: null, base_sha: "@BASE", head: null,
                    artifact: null, handoff: null, died_reason: null, validation: null, last_text: null, reason: "chain", comment_id: (arg("comment_id") | tonumber) } ],
    totals: { cost_usd: 10.5, turns: 300, role_seconds: 3000, runner_minutes: 40, overhead_minutes: 6, wakeups: 1, reworks: 0 },
    models: { honoured: true },
    flags: { hands_off: false, v1_history: false },
    memory: { pr: null, artifact: null, proposed: [] },
    refusals: {},
    log: []
  }
