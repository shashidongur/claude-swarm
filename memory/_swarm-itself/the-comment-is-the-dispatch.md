---
name: the-comment-is-the-dispatch
description: Changing how roles comment changes how they are dispatched — two silent stops in a row came from treating them as separate concerns
metadata:
  type: gotcha
---

The handoff comment is not a report *about* the dispatch. It **is** the dispatch. Every
change to how roles write must be checked against what fires them, in the same breath.

Two consecutive stalls proved it, and both looked identical from outside:

| Stage | Cause | Symptom |
|---|---|---|
| product-owner → architect | A role sets a label *and* posts a comment. Two events, one concurrency group; GitHub cancels the older pending run, and it cancelled the mention. | green run, accurate log, no next stage |
| architect → implementer | Roles were told to post a working comment then edit it into the handoff — so the mention arrived as an `edited` event, and the trigger only listened to `created`. | green run, accurate log, no next stage |

**Neither errored.** Both produced a correct log line describing a pipeline that had
stopped: *"SKIP: label swarm:design does not start the pipeline"* and *"SKIP: no mention,
nothing to dispatch"* were both true statements about a chain that was now dead.

**Why:** a mention-driven pipeline has no orchestrator watching for stalls. Every other
architecture has something that notices work stopped moving; this one has nothing between
"a role finished" and "the next role started" except a GitHub event firing correctly.

**How to apply:**

1. When changing the audit format, the working-comment protocol, or anything a role does
   at the end of a stage, **re-read the workflow triggers in the same change**. If the
   role now writes at a different moment, in a different event, or with different
   content, the trigger has to move with it.
2. A silent stall is the default failure of this design. Assume it, and look for it:
   after any change, drive one real handoff and confirm the *next* run started — a green
   run on the stage you changed proves nothing.
3. The warden should watch for issues whose newest `kind=stage` comment carries a mention
   with no dispatch run after it. That is the signature, and nothing currently detects it.
