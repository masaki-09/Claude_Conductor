# Token Budget Heuristics

Rough rules of thumb for the conductor. None of these are hard limits — they're triggers that should make you reach for `gc-parallel.sh` instead of doing the work in-context.

## Always delegate

| Trigger | Why |
|---|---|
| Reading a file >200 lines | Workers can ingest the file once and emit a 2-line summary |
| Writing/editing >50 lines of code in one place | Worker writes to disk; you read a summary, not the code |
| Generating tests for a module | Boilerplate-heavy, well-suited to a cheaper model |
| Refactoring N files for the same pattern | N parallel workers, disjoint paths |
| Cross-file search where grep+read won't suffice | Worker can read freely; you only see the answer |
| Producing docs, READMEs, changelogs | Long output tokens — exactly what we're avoiding |
| Codemods / migrations / renames at scale | Same as above, plus parallelizes cleanly |
| Translating or rewriting large prose blocks | Output-heavy |

## Probably delegate

| Trigger | Caveat |
|---|---|
| Implementing a function 30–50 lines | Worth the overhead if you don't already have the surrounding file loaded |
| Adding a small feature to an existing file | Delegate if the file is large and you haven't read it yet |
| Writing a single small test | Delegate if writing it in-context would force you to read the whole module |

## Keep in-context

| Situation | Why |
|---|---|
| Architecture decisions, trade-off analysis | Needs Claude-grade reasoning under ambiguity |
| Splitting work into parallel sub-tasks | This is the conductor's actual job |
| Reading worker summaries and exit codes | Cheap by construction |
| Resolving a merge/integration conflict between two batches | Needs holistic view |
| Talking to the user, asking clarifying questions | No workers in this loop |
| Tiny ad-hoc tweaks (<30 lines, file already in context) | Spawning overhead exceeds the savings |

## Self-audit checklist

Before declaring a session done, sanity-check:

- Did I personally read any file >200 lines? If yes → next time, delegate that.
- Did I write any code block >50 lines in my own messages? If yes → that should have been a worker.
- Did I run more than one batch in series when they could have been one parallel batch? If yes → wider batches next time.
- Did I read any `*.log` file? If no failures, that's wasted tokens.

If your token usage looks like a normal Claude Code session, the Conductor pattern wasn't really applied.
