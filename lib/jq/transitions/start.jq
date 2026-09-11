# start — builds the initial state document (input: null or {}; a document that
# already exists is a precondition error — resolve calls `resume` for a parked /
# blocked / dropped issue). Queues the first dispatch.
#   --arg issue N  --arg repo o/r  --arg now  --arg by <login>
#   --arg stage <first stage>  --arg role <first role>          (triage/triage, or requirements/analyst when a path is forced)
#   [--arg path full|short] [--arg path_source owner]           forced path
#   [--arg swarm_sha] [--arg pipeline_sha] [--arg config_sha] [--arg state_comment_id N]
#   [--arg budget 5] [--arg question_rounds 2] [--arg v1_history true] [--arg model <id>] [--arg note …]
include "_lib";
pre((. == null) or (type == "object" and (has("v") | not)); "state already exists (created_at \(.created_at // "?"))")
| (need("issue") | toint) as $issue
| (need("stage")) as $stage
| (need("role")) as $role
| (opt("path"; "full")) as $path
| {
    v: 2,
    issue: $issue,
    repo: need("repo"),
    created_at: ts,
    swarm_sha: opt("swarm_sha"; null),
    pipeline_sha: opt("pipeline_sha"; null),
    config_sha: opt("config_sha"; null),
    state_comment_id: (if has_arg("state_comment_id") then (arg("state_comment_id") | toint) else null end),
    path: $path,
    path_source: (if has_arg("path") then opt("path_source"; "owner") else "triage" end),
    triage: null,
    lanes: [],
    stage: $stage,
    status: "queued",
    current: null,
    next: null,
    gate: null,
    evidence: { pending: null, seen: {}, fires: {} },
    branch: null, head: null, pr: null,
    merged_at: null, merged_pr: null, merge_sha: null, merged_by: null,
    subissues: { flat: false },
    pending_artifacts: [],
    rework: { spent: 0, budget: opt_int("budget"; 5), reset_at: null, log: [] },
    questions: { rounds: 0, max: opt_int("question_rounds"; 2), comment_id: null },
    stages: (reduce stage_order[] as $s ({}; .[$s] = {status: "pending", attempts: {}})),
    dispatches: [],
    totals: { cost_usd: 0, turns: 0, role_seconds: 0, runner_minutes: 0, overhead_minutes: 0, wakeups: 0, reworks: 0 },
    models: { honoured: true },
    flags: { hands_off: false, v1_history: (opt("v1_history"; "false") == "true") },
    memory: { pr: null, artifact: null, proposed: [] },
    refusals: {},
    log: []
  }
| (if $path == "short" then .stages.design.status = "skipped" | .stages.architecture.status = "skipped" else . end)
| queue($stage; $role; "start")
| log_event("start")
