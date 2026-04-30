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

The full rationale lives in [`CLAUDE.md`](CLAUDE.md), [`docs/workflow.md`](docs/workflow.md), and [`docs/token-budget.md`](docs/token-budget.md). `CLAUDE.md` is auto-loaded by Claude Code when a session starts in this repo, so the workflow rules are in effect with no further setup.

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

# Run the example batch end-to-end
scripts/gc-parallel.sh examples/hello-batch --max-parallel 2
ls examples/hello-batch/output/
cat examples/hello-batch/*.summary
```

Then start Claude Code from this directory:

```bash
claude
```

`CLAUDE.md` will be loaded as your standing instructions. Tell Claude something like *"use Conductor mode for the rest of this session"* and proceed normally — Claude will dispatch heavy work to Gemini workers automatically.

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
│   └── worker-preamble.md   # Prepended to every worker prompt
├── scripts/
│   ├── gc-parallel.sh       # The dispatcher (main entry point)
│   ├── gc-dispatch.sh       # One-shot single-worker convenience wrapper
│   └── gc-check.sh          # Environment sanity check
├── docs/
│   ├── workflow.md          # Detailed workflow + diagrams
│   └── token-budget.md      # What to delegate vs. keep in-context
├── examples/
│   └── hello-batch/         # Minimal runnable example
└── tasks/                   # gitignored — ephemeral batch dirs
```

## Status

Personal tool. Open-sourced under MIT in case the pattern is useful to others. APIs and conventions may change without notice until a 1.0 tag.

## License

[MIT](LICENSE)
