# Claude Conductor

> A pattern (and a tiny toolkit) for combining **Claude Code's** reasoning with **Gemini CLI's** cheap throughput.

Claude Code is excellent at planning, decomposition, and judgment under ambiguity — and expensive on long agentic sessions because every read and every edit costs context tokens. Gemini CLI is the opposite trade-off: cheap and fast on bulk work, less reliable as a top-level architect.

**Claude Conductor** keeps Claude Code in the conductor seat and dispatches the heavy work to a swarm of 4–6 Gemini CLI workers in parallel. The conductor never reads the workers' full output — only short structured summaries.

The result: Claude Code spends its tokens on design, decomposition, and integration. Gemini does the typing.

## How it works

```
Claude Code (conductor)
   │  writes one *.prompt file per parallel worker
   ▼
scripts/gc-parallel.sh tasks/<batch>
   │  spawns 4–6 `gemini -p ...` workers concurrently
   ▼
Workers write code/files directly to the project tree (yolo mode)
   │  emit STATUS / FILES / NOTES summary (<500 chars)
   ▼
Claude Code reads only the *.summary and *.exitcode files
```

Three kinds of workers do the heavy lifting, with model selection tuned to each role:

| Worker | Purpose | Mode | Default model |
|---|---|---|---|
| **Recon** | Read the codebase once and produce a structured map (LAYERS, KEY_MODULES, CONVENTIONS, CHECK_COMMANDS). Replaces Claude reading source files. | read-only | `gemini-3-pro-preview` |
| **Implementer** | Do the actual edits. 4–6 in parallel by default. | write | `gemini-3-flash-preview` |
| **Reviewer** | Audit the diff after a batch and report BLOCKERS/WARNINGS/NITS. Replaces Claude reading code to verify. | read-only | `gemini-3-pro-preview` |

Reviewers come in **four perspectives**: `general`, `security`, `perf`, `api`. Run them alone or all-at-once with `--aspects all`. With `--until-clean`, the reviewer can also drive an autoloop: review → auto-dispatch a fix worker → re-review, repeating until clean or `--max-iters` (default 3) is hit.

**v0.4** adds three things on top:
- **Per-worker retry + quota-aware fallback** (`--retries N --fallback-model NAME`) so one transient 429 doesn't kill a whole parallel batch.
- **Token telemetry** — every worker writes `<id>.usage.json` with prompt/completion/total tokens; per batch a `_batch.usage.json` aggregates. New `scripts/gc-stats.sh` rolls these up over `--since 24h` (or any window) and reports estimated cost.
- **Diff-pack pre-build for reviewers** — `gc-review.sh` runs `git diff` once and feeds the result to all aspect reviewers as context, instead of each reviewer re-issuing git commands. Reduces redundant tokens and round-trip latency on multi-aspect runs.

## v0.5 — Session checkpoint & rate-limit-safe resume

Long-running agentic sessions often hit Claude's rate limits or context pressure, leading to "lost" work when a session is interrupted. v0.5 introduces a robust event log and state-checkpointing mechanism that allows a new Claude session to pick up exactly where the last one left off, with full visibility into recent worker activity and plan progress.

- **Transparent event log**: `tasks/_session/events.jsonl` is written to by every `gc-*` script, tracking batch lifecycle and worker outcomes.
- **On-demand briefing**: `scripts/gc-resume.sh` aggregates the log, git state, and your `plan.md` into a single `state.md` briefing.
- **Auto-checkpoint**: `scripts/gc-checkpoint.sh` can be wired to Claude Code's "Stop" hook to automatically regenerate the briefing at the end of every turn.

## v0.6 — Gemini-side rate-limit resilience

Gemini Pro daily quota can hard-pause a multi-batch session for hours. Without v0.6, those workers were marked failed and lost. Version 0.6 adds:

- **Hard-limit detection** — workers that hit a quota cap are saved as `paused-quota` with re-dispatch metadata, not destroyed.
- **`gc-resume-workers.sh`** — replays paused workers when their reset window has passed, on demand.
- **`gc-watch.sh`** — optional always-on watcher that auto-resumes paused workers (run with `nohup` or in `tmux`/`screen`).

## v0.7 — Recon delta

Long sessions cause the initial recon map to drift from the actual state of the codebase. Re-running a full recon every batch is wasteful (25k+ tokens). v0.7 introduces incremental updates:

- **Versioned maps** — every recon map records `RECON_AT: <sha>` so future tools can compute the delta.
- **`gc-recon-delta.sh`** — incremental update. Reads the existing map, sees `git diff <sha>..HEAD`, and asks the delta worker to refresh only what changed.
- **Staleness hint** — `gc-resume.sh`'s briefing tells the conductor when a delta or full re-recon is due based on commit volume and time.

```bash
scripts/gc-recon-delta.sh                # auto: refresh tasks/_recon/recon.md
scripts/gc-recon-delta.sh --suggest-full # bail out if too many files changed (>30)
scripts/gc-recon-delta.sh --since <sha>  # explicit baseline
```

### Setup (optional)

```bash
# In tmux/screen: keep a watcher running for the session
scripts/gc-watch.sh --interval 600
# Or one-shot:
scripts/gc-resume-workers.sh --all
```

### Setup (Stop hook)

To enable auto-checkpointing, add the following to your `~/.claude/settings.json` (replace `/path/to/conductor` with the absolute path to this repo):

```json
"hooks": {
  "Stop": "/path/to/conductor/scripts/gc-checkpoint.sh"
}
```
See `examples/stop-hook-snippet.json` for a complete fragment.

Operating guide: [`docs/usage.md`](docs/usage.md). Rules Claude itself follows: [`CLAUDE.md`](CLAUDE.md). Rationale and heuristics: [`docs/workflow.md`](docs/workflow.md), [`docs/token-budget.md`](docs/token-budget.md). `CLAUDE.md` is auto-loaded by Claude Code when a session starts in this repo.

## Requirements

- **Claude Code** (CLI) — https://claude.com/claude-code
- **Gemini CLI** ≥ 0.39 — https://geminicli.com (`npm i -g @google/gemini-cli` or equivalent)
- **bash** ≥ 4.3 (Git Bash on Windows works)
- **git**

## Quick start

```bash
git clone git@github.com:masaki-09/Claude_Conductor.git
cd Claude_Conductor

# Verify environment
scripts/gc-check.sh

# (a) Run the implementer example end-to-end (2 parallel workers)
scripts/gc-parallel.sh examples/hello-batch --max-parallel 2
cat examples/hello-batch/*.summary

# (b) Run a recon on this repo and read the structured map
scripts/gc-recon.sh --out tasks/_recon/recon.md "Recon this repository"
cat tasks/_recon/recon.md
```

Then start Claude Code from this directory:

```bash
claude
```

`CLAUDE.md` is auto-loaded. Tell Claude *"use Conductor mode"* and proceed normally — Claude will run recon, dispatch parallel implementers with the recon as context, and run a reviewer between batches, all on its own. See [`docs/usage.md`](docs/usage.md) for the full operator's guide.

## Using Conductor in another project

Two options:

**Option A — clone alongside, reference by path.**

```bash
git clone git@github.com:masaki-09/Claude_Conductor.git ~/tools/Claude_Conductor
cd ~/your/project
ln -s ~/tools/Claude_Conductor/CLAUDE.md ./CLAUDE.md   # or copy
# Use scripts via absolute path:
~/tools/Claude_Conductor/scripts/gc-parallel.sh tasks/batch1
```

**Option B — add as a submodule.**

```bash
cd ~/your/project
git submodule add git@github.com:masaki-09/Claude_Conductor.git .conductor
ln -s .conductor/CLAUDE.md ./CLAUDE.md
.conductor/scripts/gc-parallel.sh tasks/batch1
```

Either way, `CLAUDE.md` should be present at the project root so Claude Code picks it up.

## Project layout

```
.
├── CLAUDE.md                # Auto-loaded operating manual for Claude Code
├── README.md                # This file
├── LICENSE                  # MIT
├── prompts/
│   ├── worker-preamble.md   # Implementer worker contract (writes files, returns summary)
│   ├── recon-preamble.md    # Recon worker contract (read-only project map)
│   └── reviewer-preamble.md # Reviewer worker contract (read-only diff audit)
├── scripts/
│   ├── gc-parallel.sh       # The dispatcher (main entry point)
│   ├── gc-recon.sh          # Read-only recon worker
│   ├── gc-review.sh         # Read-only diff reviewer
│   ├── gc-dispatch.sh       # One-shot single-worker convenience wrapper
│   └── gc-check.sh          # Environment sanity check
├── docs/
│   ├── usage.md             # Operator's guide (start here for "how do I drive this")
│   ├── workflow.md          # Detailed workflow + diagrams
│   └── token-budget.md      # What to delegate vs. keep in-context
├── examples/
│   └── hello-batch/         # Minimal runnable example
└── tasks/                   # gitignored — ephemeral batch dirs
```

## Status

Personal tool. Open-sourced under MIT in case the pattern is useful to others. APIs and conventions may change without notice until a 1.0 tag.

See [`ROADMAP.md`](ROADMAP.md) for the planned path to v1.0.0 (currently shipping v0.6.0).

## License

[MIT](LICENSE)
