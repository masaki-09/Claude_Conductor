# Workflow in Detail

This is the long-form companion to `CLAUDE.md`. The short version lives there; this is the rationale.

## Why this pattern exists

Claude Code's reasoning quality is best-in-class, but every token of file content it reads or writes counts against its context. Long agentic sessions burn context on file I/O that doesn't benefit from Claude-grade reasoning — boilerplate, refactoring sweeps, test scaffolding, multi-file edits with a clear pattern.

Gemini CLI is cheap and fast on those tasks but weaker at high-level decomposition and architecture under ambiguity.

**The pattern:** keep Claude Code in the conductor seat (planning, decomposition, integration) and push the bulk-token work down to a swarm of Gemini CLI workers. The conductor never sees the full text the workers produce — only short structured summaries.

## The data flow

```
┌──────────────────┐                                ┌──────────────────────┐
│  Claude Code     │  writes tasks/<batch>/*.prompt │  filesystem          │
│  (Conductor)     │ ─────────────────────────────► │  one prompt per      │
│                  │                                │  parallel worker     │
└────────┬─────────┘                                └──────────┬───────────┘
         │                                                     │
         │ runs scripts/gc-parallel.sh tasks/<batch>           │
         ▼                                                     ▼
┌──────────────────┐    spawns N workers in parallel    ┌─────────────┐
│  gc-parallel.sh  │ ──────────────────────────────────►│  gemini -p  │ × N
└──────────────────┘                                    └──────┬──────┘
         ▲                                                     │
         │                       writes code/files directly    │
         │                       to project tree (yolo mode)   │
         │                                                     ▼
         │     <id>.summary  ◄── parses STATUS/FILES/NOTES from <id>.log
         │     <id>.exitcode
         │     <id>.status
         │
         │ Conductor reads ONLY *.summary + *.exitcode (small)
         ▼
   continue planning the next batch
```

The conductor never reads `*.log`. Logs are recorded for forensic use only — if a summary says `STATUS: failed`, the conductor opens the log to diagnose; otherwise it stays closed.

## The "what to delegate" decision

Use this rough flowchart in your head:

1. Is the task **read- or write-heavy**? (>200 lines either direction) → delegate.
2. Is it **N similar things** with no cross-coupling? (3 modules, 10 file renames, 5 test files) → delegate to N parallel workers.
3. Is it **architecture, decomposition, or integration judgment**? → conductor handles in-context.
4. Is it **<30 lines** and you already have the full surrounding context loaded? → just do it; spawning has overhead.
5. Is it **ambiguous and would benefit from clarifying questions**? → conductor handles, because workers can't ask.

## Splitting parallel work safely

The hard constraint: **no two parallel workers may write to the same file**. Mistakes here cause silent overwrites, since both workers run with `--approval-mode yolo`.

Common safe splits:
- **By module/file**: worker A owns `src/auth/*`, worker B owns `src/billing/*`.
- **By layer**: worker A writes the implementation file, worker B writes its test file.
- **By migration**: worker A modifies the schema file, worker B writes the migration script (different files).

Common unsafe splits — run sequentially or merge into one worker:
- Two workers both editing `package.json`.
- One worker creating `src/foo.ts` while another imports from it.
- A formatter or codemod that touches every file.

When in doubt, sequence two batches instead of one wide parallel batch.

## When a batch fails

If `gc-parallel.sh` exits non-zero or any `*.status` is not `ok`:

1. Read the failed worker's `*.summary` first. Most failures explain themselves there.
2. Only if the summary is uninformative, read the relevant slice of `*.log`.
3. Decide: re-prompt the same worker (write a new prompt that fixes the gap), narrow its scope, or take the work back into the conductor.

A failed worker that produced partial files is normal. `git status` / `git diff` is the cheapest way to see what actually changed without re-reading code.

## Cost control summary

| Cost lever | How it's enforced |
|---|---|
| Conductor input tokens | `*.summary` ≤ ~500 chars by preamble contract |
| Conductor output tokens | Conductor writes prompts (short) and short replies, not code |
| Worker correctness | Prompts name exact files + acceptance criteria |
| Wall-clock time | 4–6 workers in parallel via `--max-parallel` |
| Blast radius | Disjoint file scopes per worker; commit between batches |
