---
name: swarm-memory
description: Read, write, and compact the swarm's per-project memory. Use at the start of every stage to load what is known about a project, and at the end to record what was learned.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

A cloud routine keeps no state between runs. Memory is git, or it does not exist.

## Location

    memory/github.com/<owner>/<repo>/
      MEMORY.md          index: one line per memory, loaded first
      conventions.md     how this project works
      preferences.md     how the owner wants work done here
      decisions.md       choices made, and why
      gotchas/*.md       traps found the hard way
      agents/*.md        this project's own specialist roles
      issues/<n>.md      working notes for one item

## Format

One fact per file. Frontmatter, then the fact:

```markdown
---
name: <short-kebab-case-slug>
description: <one line, used to judge relevance>
metadata:
  type: preference | convention | gotcha | decision | reference
---

<the fact. For a preference or a gotcha, follow with **Why:** and **How to apply:**.
Link related memories with [[their-name]].>
```

`MEMORY.md` carries one line per memory: `- [Title](path.md) — hook`. It is the index a
run reads first, so it decides what gets loaded at all.

## Reading

Load `MEMORY.md`, then the files whose descriptions bear on the current stage. Not all
of them — a role that loads everything learns nothing.

**Verify before you rely.** A note naming a file, a function, or a flag is checked
against the current tree before you act on it. Memory records what was true when it was
written. A note contradicted by the code is corrected in place, in the same run that
found it wrong — a stale note that survives is worse than a missing one, because the
next run will believe it.

## Writing

Before writing, search for an existing note that covers the same ground. Update that
file rather than creating a second one; `MEMORY.md` is the dedupe index and duplicate
entries are the failure mode that makes memory useless.

Write a note when:

- the owner corrected you, and the correction generalises — that is a **preference**
- you lost time to something non-obvious about this codebase — that is a **gotcha**
- a question was settled that would otherwise be reopened — that is a **decision**
- you learned how this project actually runs its checks — that is a **convention**

Do not write what the repository already records. Code structure, git history, and the
project's own instructions file are read directly, not copied into memory. If something
seems worth remembering but is already written down elsewhere, record the *pointer*, not
the content.

`issues/<n>.md` is different: it is working state, written continuously, so a run that
dies mid-stage resumes with context instead of starting over. It is deleted when the
issue closes.

## Compacting

Memory that only grows becomes noise. On a schedule:

- merge near-duplicate notes into the older file, keeping its name
- delete notes the code now contradicts
- keep `MEMORY.md` near forty lines per project; past that, something needs merging

## Committing

`memory/**` commits directly to the default branch of this repository — learning is not
gated. Everything else here requires a pull request. Commit message:

    memory(<owner>/<repo>): <what was learned, in one line>
