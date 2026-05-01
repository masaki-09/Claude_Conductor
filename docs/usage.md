# Usage — How to drive Claude Conductor

This is the operator's guide. Read [CLAUDE.md](../CLAUDE.md) for the rules Claude Code itself follows; read this for what *you* type.

## 0. Prerequisites (one-time)

```bash
# 1. Install Gemini CLI (if you haven't)
npm i -g @google/gemini-cli
gemini --version            # expect ≥ 0.39

# 2. Authenticate Gemini CLI once interactively
gemini                      # follow the auth prompt, then Ctrl+D to exit

# 3. Clone the repo
git clone git@github.com:masaki-09/Claude_Conductor.git
cd Claude_Conductor
scripts/gc-check.sh         # all entries should be "ok"
```

If `gc-check.sh` reports anything red, fix that before continuing — workers will fail silently otherwise.

## 1. Two ways to start a session

### A. Work *inside* this repo (simplest)

```bash
cd Claude_Conductor
claude                      # Claude Code auto-loads CLAUDE.md
```

Then in the chat: *"Use Conductor mode. Build me a small CLI tool that..."*

### B. Use Conductor *on another project*

Pick one of these layouts:

```bash
# Option B1 — clone next to your project, symlink CLAUDE.md
git clone git@github.com:masaki-09/Claude_Conductor.git ~/tools/Claude_Conductor
cd ~/your/project
ln -s ~/tools/Claude_Conductor/CLAUDE.md ./CLAUDE.md
claude
# In chat, instruct Claude to use ~/tools/Claude_Conductor/scripts/* (absolute paths).

# Option B2 — submodule
cd ~/your/project
git submodule add git@github.com:masaki-09/Claude_Conductor.git .conductor
ln -s .conductor/CLAUDE.md ./CLAUDE.md
claude
# Scripts live at .conductor/scripts/*
```

Either way, `CLAUDE.md` must be at your project root for Claude Code to auto-load it.

## 2. The standard loop (what Claude does each turn)

Claude follows this loop on its own once Conductor mode is in effect. You only need to know it so you can spot when something's off.

```
                   ┌─────────────────────────────────────────────┐
                   │ 1. recon  (once per project, or when stale) │
                   │    scripts/gc-recon.sh --out tasks/_recon/recon.md
                   └────────────────────┬────────────────────────┘
                                        ▼
                   ┌─────────────────────────────────────────────┐
                   │ 2. plan + decompose into disjoint file sets │
                   │    Claude writes tasks/<batch>/<id>.prompt  │
                   └────────────────────┬────────────────────────┘
                                        ▼
                   ┌─────────────────────────────────────────────┐
                   │ 3. dispatch implementers (4–6 in parallel)  │
                   │    scripts/gc-parallel.sh tasks/<batch>     │
                   │      --context-file tasks/_recon/recon.md   │
                   └────────────────────┬────────────────────────┘
                                        ▼
                   ┌─────────────────────────────────────────────┐
                   │ 4. read *.summary, git commit               │
                   └────────────────────┬────────────────────────┘
                                        ▼
                   ┌─────────────────────────────────────────────┐
                   │ 5. review (read-only)                       │
                   │    scripts/gc-review.sh                     │
                   └────────────────────┬────────────────────────┘
                                        ▼
                   ┌─────────────────────────────────────────────┐
                   │ 6. issues? → fix batch (back to step 2)     │
                   │    clean? → next feature or hand back to user │
                   └─────────────────────────────────────────────┘
```

## 3. Worked example

Suppose you're working in a TypeScript project and ask Claude:

> Add a rate limiter middleware (token bucket, configurable RPM/burst), wire it into the Express app, and add tests.

What you'll see Claude do:

```bash
# Step 1: recon (first time only)
scripts/gc-recon.sh --out tasks/_recon/recon.md
# → Claude reads tasks/_recon/recon.md, learns:
#     CHECK_COMMANDS: typecheck=pnpm tsc, test=pnpm vitest
#     CONVENTIONS: errors via Result<T,E>, middleware in src/middleware/
#     KEY_MODULES: src/app.ts builds the Express instance

# Step 2-3: implement in parallel (3 disjoint scopes)
mkdir -p tasks/rl-001
# Claude writes:
#   tasks/rl-001/limiter.prompt        — implements src/middleware/rateLimit.ts
#   tasks/rl-001/wire.prompt           — modifies src/app.ts
#   tasks/rl-001/tests.prompt          — creates src/middleware/rateLimit.test.ts
scripts/gc-parallel.sh tasks/rl-001 \
  --context-file tasks/_recon/recon.md \
  --max-parallel 3
# → Each prompt includes: "After edits, run `pnpm tsc && pnpm vitest src/middleware/rateLimit.test.ts`. Report pass/fail in NOTES."

# Step 4: Claude reads only *.summary (≤500 chars each), commits
git add -A && git commit -m "rate-limiter: token-bucket middleware + tests"

# Step 5: review (autoloop variant — review → autofix → re-review until clean)
scripts/gc-review.sh --aspects general,security,perf --until-clean \
  --check-cmd "pnpm tsc && pnpm vitest src/middleware/rateLimit.test.ts" \
  --max-iters 3
# → tasks/review-*/<aspect>.summary lists per-perspective BLOCKERS / WARNINGS
# → if any aspect is non-clean, an autofix iteration runs automatically

# Step 6: clean → done. Claude reports a 1–3 sentence summary to you.
```

Throughout this, Claude has **never read** `src/middleware/rateLimit.ts`, `src/app.ts`, or the test file. It read the recon map, the worker summaries, and the review summary. That's the entire point.

## 4. Manual operations (when Claude isn't driving)

You can run any of these yourself between Claude turns to inspect state:

```bash
# What did the most recent batch produce?
ls tasks/<batch-id>/
cat tasks/<batch-id>/*.summary

# Did a worker fail? Inspect its log.
cat tasks/<batch-id>/<id>.log

# Re-run a single worker after fixing its prompt
scripts/gc-parallel.sh tasks/<batch-id>           # re-runs all *.prompt files in dir
# or move the others aside first

# Run a one-off
scripts/gc-dispatch.sh "Add a CHANGELOG.md entry for v0.2 listing X, Y, Z" \
  --context-file tasks/_recon/recon.md

# Refresh the recon map (after large changes)
scripts/gc-recon.sh --out tasks/_recon/recon.md

# Review uncommitted staged changes
git add -A
scripts/gc-review.sh --staged
```

## 5. Tuning

| Knob | Where | When to touch |
|---|---|---|
| `--max-parallel N` | `gc-parallel.sh` | Default 4. Raise to 6 for many small tasks; lower to 2 if your machine or rate limits suffer. |
| `--model NAME` | any dispatcher | Defaults: implementer=`gemini-3-flash-preview` (cheap, fast), recon/review=`gemini-3-pro-preview` (accurate). Override per-call. |
| `--include path1,path2` | any dispatcher | Add directories outside cwd to the worker's reachable workspace. |
| `--cwd path` | any dispatcher | Run workers in a different project root. Useful for monorepos or sandbox demos. |
| `--context-file path` | `gc-parallel.sh` | Path to recon map. **Always set this** for implementer batches. |
| `--aspects <list>` | `gc-review.sh` | Comma list of `general`, `security`, `perf`, `api`, or `all`. Each aspect runs as its own parallel reviewer. Default is `general`. |
| `--until-clean` | `gc-review.sh` | Autoloop: after a non-clean review, dispatch a fix worker, commit, re-review. Stops when clean or `--max-iters` (default 3) is hit. Pair with `--check-cmd` so the fixer self-validates. |

## 6. Troubleshooting

**Worker `STATUS: failed` or non-zero exit code.** Read the matching `*.log`. Common causes:
- Auth: re-run `gemini` once interactively to refresh credentials.
- Rate limit: lower `--max-parallel`.
- Prompt too vague: workers can't ask questions; they bail. Tighten scope and re-dispatch.

**Worker wrote to a file outside its scope.** The preamble forbids this but a sloppy prompt can cause it. `git diff` to see; `git checkout -- <bad-file>` to revert; tighten the prompt.

**Workers drifting from project conventions.** You forgot `--context-file`. Always pass the recon map.

**Conductor still burning many tokens.** Audit:
- Did Claude read source files instead of running recon? Tell it explicitly: *"Run gc-recon first; do not read source files."*
- Did Claude read `*.log`? It shouldn't unless a worker failed.
- Did Claude write code blocks in chat instead of dispatching? That defeats the pattern — re-prompt with *"dispatch this, don't paste the code in chat."*

**`wait -n` errors on bash 4.2 or older.** The dispatcher needs bash ≥ 4.3. Git Bash on Windows ships 4.4+; on macOS install bash via Homebrew.

## 7. Hygiene

Between sessions:

```bash
# Old batches accumulate in tasks/. They're gitignored (logs/summaries/etc),
# but the *.prompt files stay. Trim them periodically:
rm -rf tasks/recon-* tasks/review-* tasks/oneshot-*
# Keep tasks/_recon/recon.md (it's what you pass to --context-file).
```
