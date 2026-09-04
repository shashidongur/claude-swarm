# Leasing — claim, renew, reclaim

Labels record state. They cannot lock it: the GitHub API has no compare-and-set on
labels, so two routines can both read "unclaimed" and both write "claimed".

Git refs do have one:

- `POST /git/refs` returns `422 Reference already exists` — atomic create-if-absent.
- `PATCH /git/refs` with `force: false` succeeds only as a fast-forward — a true CAS on
  the value you read.

**The ref is the truth. The label and the comment are its projection.** Before acting,
always re-read the ref and compare `run=` to your own run id.

## The lease

Ref: `refs/heads/claude/lease/issue-<N>` — under `claude/` because that is the prefix a
routine may push, and inert with respect to CI, which triggers on `main` and on
pull requests only.

Tip commit message (parseable, and readable in the GitHub UI):

    swarm-lease v1

    issue=44
    routine=pipeline-tick
    run=<routine run id>
    stage=build
    claimed=2026-09-03T10:04:11Z
    expires=2026-09-03T13:04:11Z
    branch=claude/issue-44-20260903-1004
    generation=1

`generation` increments on every takeover, so a stalled routine that wakes up can tell
it was preempted.

## Claim

    0. Read the Swarm Control issue. Closed, or labelled swarm:halt -> exit.
       If that read FAILS for any reason -> exit. Fail closed.
    1. Read the issue's labels.
       swarm:hands-off present            -> skip
       swarm:* not a state this lane owns -> skip
    2. Build a PARENTLESS commit whose message is the lease record, so the lease
       lineage never touches main.
    3. POST /git/refs
         201 -> won
         422 -> read the existing lease; either reclaim (below) or skip
    4. Only after winning the ref: add the state label, and comment
         <!-- swarm: v1 | kind=lease | issue=N | run=<run> | gen=<g> | expires=<ts> -->
    5. Proceed.

Steps 3 and 4 are not atomic together, and that is deliberate. A crash between them
leaves a ref with no label; the warden reconciles it by trusting the ref.

## Renew

Routines have no timers, so heartbeat on stage boundaries rather than on a clock:

    cur = GET ref
    if parse(cur).run != my run -> raise Preempted; abandon, do not push
    c2  = commit(payload with new stage, expires=now+3h, same generation, parents=[cur])
    PATCH ref {sha: c2, force: false}
      200 -> ok
      422 -> raise Preempted

`force: false` is load-bearing. It is what turns read-then-write into CAS.

## Reclaim a stale lease

Expiry alone is not enough — a slow stage is not a dead one.

    cur = GET ref; L = parse(cur)
    if now < L.expires                                   -> refuse
    if branch L.branch has a commit newer than 45 min    -> refuse
    if an open PR from L.branch moved head < 45 min ago  -> refuse
    c2 = commit(routine=me, run=my run, generation=L.generation+1, parents=[cur])
    PATCH ref {sha: c2, force: false}    # exactly one reclaimer wins
    comment kind=lease-reclaim, naming the dead run and its branch

## A routine died mid-work

**Never destroy work you did not create in this run.**

    branch absent, or 0 commits ahead of main
        -> delete branch and lease ref, return the issue to its ready state
    branch has commits, no PR, younger than 7 days
        -> KEEP the branch. Set blocked:orphan. Comment with the branch name, commit
           count, and files touched. Delete the lease ref so the item is claimable, and
           record resume=<branch> so the next claimant starts from it, not from main.
    branch has commits, no PR, older than 7 days or no longer applies to main
        -> archive to refs/tags/swarm-archive/issue-N-<date>, then delete the branch
    an open PR exists
        -> the PR is the state. Delete the lease ref only. Never delete the branch.
