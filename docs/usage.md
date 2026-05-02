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
| `--retries N` | any dispatcher | Per-worker retries on transient failures (429, RESOURCE_EXHAUSTED, UNAVAILABLE, INTERNAL, DEADLINE_EXCEEDED). Default 0 = single attempt. Backoff is exponential (2s, 6s, 18s). |
| `--retry-on PATTERN` | any dispatcher | Extra regex on top of the built-in transient set, OR-ed in. Useful when a workload-specific error string also justifies a retry. |
| `--fallback-model NAME` | any dispatcher | After exhausting retries, do one final attempt with this model. On success the worker's status becomes `ok-fallback` (or `partial-fallback`). Repeated fallbacks in `gc-stats.sh` mean the primary model is wrong-sized. |

## 4.5 Inspecting token spend

`gc-stats.sh` aggregates per-worker `*.usage.json` and per-batch `_batch.usage.json` files written automatically by every `gc-parallel.sh` run.

```bash
# Last 24 hours, breakdown by model (default)
scripts/gc-stats.sh

# Last 7 days, broken down by worker_type (recon|impl|review|autofix|oneshot)
scripts/gc-stats.sh --since 7d --by worker_type

# Everything since a specific batch
scripts/gc-stats.sh --since-batch v04-b1 --by status

# Machine-readable for scripting
scripts/gc-stats.sh --json --since 24h
```

Pricing constants live in `gc-stats.sh` and use public list pricing as of the release date — costs are estimates, not invoices.

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

## 8. Session checkpoint & resume (v0.5)

### 8.1 What it is

A persistent record of in-progress work that survives Claude rate-limit pauses, manual session ends, and machine reboots. Three pieces:

- `tasks/_session/events.jsonl` — append-only event log written by every gc-* script. Records batch_start/end, recon_start/end, review_start/end, autofix_start/end, dispatch_start/end with timestamps and key fields.
- `tasks/_session/plan.md` — the conductor's plan, written and maintained by Claude (per CLAUDE.md instruction).
- `tasks/_session/state.md` — auto-generated briefing combining the above with `git log` and `git status`. This is what Claude reads on resume.

### 8.2 Manual operations

```bash
# Print the current briefing to stdout (also writes state.md)
scripts/gc-resume.sh

# Filter recent activity to the last 6 hours
scripts/gc-resume.sh --since 6h

# Update state.md silently (used by Stop hook)
scripts/gc-resume.sh --quiet

# Just print, don't touch state.md
scripts/gc-resume.sh --no-write
```

### 8.3 Wiring the Stop hook (one-time)

To make state.md regenerate automatically every turn:

1. Open or create `~/.claude/settings.json` (or `.claude/settings.json` in your project for per-project config).
2. Merge in the snippet from `examples/stop-hook-snippet.json`. Replace `<REPO_ROOT>` with the absolute path to your Claude_Conductor checkout.
3. Restart your Claude Code session. The hook fires every time Claude finishes responding.

Verify: complete one turn in any session, then `cat tasks/_session/state.md` — the file should reflect the latest events.

### 8.4 What happens on a rate-limit pause

```
Claude work in flight
   ↓
Anthropic rate-limit hit, session interrupted
   ↓
Stop hook fires → gc-checkpoint.sh → gc-resume.sh --quiet
   ↓
tasks/_session/state.md saved with full briefing
   ↓
~~ wait for limit to lift (Pro plan: ~5h reset window) ~~
   ↓
User opens new Claude Code session
   ↓
CLAUDE.md instruction → Claude reads state.md and plan.md FIRST
   ↓
Claude resumes from the first unchecked [ ] item in plan.md
```

The user types nothing special. If the Stop hook is NOT configured, the user runs `scripts/gc-resume.sh` once at the start of the new session — same effect, one extra command.

## 9. Gemini quota pause & auto-resume (v0.6)

### 9.1 What it is

If a Gemini Pro daily quota exhausts mid-batch, that worker's run is captured as `paused-quota` instead of `failed`. v0.6 ships two scripts that resume paused workers later: `gc-resume-workers.sh` (manual one-shot) and `gc-watch.sh` (always-on).

### 9.2 Indicators

After a batch, look for these:
- `gc-stats.sh` output has a `paused` bucket with count > 0.
- `<id>.status` file contains `paused-quota`.
- `<id>.pause.json` exists in the batch dir.
- The batch's exit code was 4 (paused-only) instead of 0.

### 9.3 Manual resume

```bash
# Dry-run: see what's eligible
scripts/gc-resume-workers.sh --all --dry-run

# Resume eligible workers in one batch
scripts/gc-resume-workers.sh tasks/<batch-id>

# Resume across all batches
scripts/gc-resume-workers.sh --all

# Force-retry even if estimated_resume_at hasn't passed (use cautiously — may hit limit again)
scripts/gc-resume-workers.sh tasks/<batch-id> --force
```

### 9.4 Always-on watcher

```bash
# Foreground (recommended in tmux/screen)
scripts/gc-watch.sh --interval 600

# One-shot for cron
scripts/gc-watch.sh --once

# Bounded runtime (auto-exit after 24h)
scripts/gc-watch.sh --max-runtime 86400
```

The watcher emits `watch_start` / `watch_tick` / `watch_stop` to `tasks/_session/events.jsonl`, so `gc-resume.sh` will surface it in the briefing.

### 9.5 Tuning the detection

The hard-limit regex inside `gc-parallel.sh` matches:
- `TerminalQuotaError`
- `Your quota will reset after \d+h`
- `retryDelayMs > 600000` (10 min)
- `QUOTA_EXHAUSTED` with `retry: false`

If your environment surfaces a different quota string, you can extend by setting an env var or editing the script (currently no flag — file an issue or PR if your error format differs).

