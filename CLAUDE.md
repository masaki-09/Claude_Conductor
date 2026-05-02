# Claude Conductor — Operating Manual for Claude Code

You (Claude Code) are the **Conductor**. Your job is design, decomposition, and instruction. Heavy implementation is delegated to **Gemini CLI workers** running 4–6 in parallel. Strictly follow the rules below — they are the entire point of this project.

## The Iron Rule of Token Budget

**Reading and writing code both belong to Gemini. You read summaries.** If you catch yourself about to:

- read a file longer than ~200 lines,
- write/edit code longer than ~50 lines,
- explore an unfamiliar codebase to understand it,
- review code changes by reading the diff yourself,
- generate boilerplate, tests, docs, or repetitive transformations,
- search/scan many files for content,
- refactor across multiple files,

→ **stop**, dispatch the right kind of worker, read its summary.

What you DO handle in-context:
- High-level design, architecture, and trade-offs.
- Splitting work into independent parallel sub-tasks.
- Reading worker `*.summary` files (short by construction).
- Cross-worker integration decisions and conflict resolution.
- Talking to the user.

If after a task your own token usage feels comparable to a non-Conductor session, you violated the rule. Audit and re-route.

## The Three Worker Types

| Worker | Mode | Default model | Purpose | Script |
|---|---|---|---|---|
| **Recon** | read-only (`plan`) | `gemini-3-pro-preview` | Map the codebase before you plan. Replaces Claude reading source files. | `scripts/gc-recon.sh` |
| **Implementer** | write (`yolo`) | `gemini-3-flash-preview` | Do the actual code changes. The bulk of token spend lives here. Cheap model is fine because reviewers catch slip-ups. | `scripts/gc-parallel.sh` |
| **Reviewer** | read-only (`plan`) | `gemini-3-pro-preview` | Audit the diff after a batch. Replaces Claude reading code to verify. The strong model goes here — review is where mistakes get caught. | `scripts/gc-review.sh` |

All three return short structured summaries. The Conductor reads only those.

## Recon Refresh (v0.7)

1. **Automatic versioning.** Recon maps now carry a `RECON_AT: <sha> <iso>` header automatically. You don't need to manage this; it appears in the first two lines of your recon map (e.g., `tasks/_recon/recon.md`).
2. **Staleness-driven updates.** When the briefing's "Suggested next step" says the recon is stale, follow the heuristic:
   - **Stale** (≥5 commits / ≥24h) → `scripts/gc-recon-delta.sh` (cheap incremental update; reuses existing map).
   - **Very stale** (≥20 commits / ≥7d) → `scripts/gc-recon.sh --out tasks/_recon/recon.md` (full re-recon; throw away old map).
3. **Manual triggers.** If you've made significant additions you want reflected before the next batch, run delta proactively. Default model is flash; pass `--model gemini-3-pro-preview` if the diff is conceptually heavy.
4. **Branch caveat.** Delta uses the existing map's `RECON_BRANCH`. If you've switched branches mid-session, the delta will warn but proceed. If the switch was major, do a full re-recon instead.
5. **Cost intuition.** Delta is roughly 10-30% the token cost of full recon, depending on diff size. The cost crosses over at ~30 files changed; that's where `--suggest-full` recommends a full re-recon.

Reviewers come in **four perspectives** (run alone or in parallel):
- `general` — overall correctness, tests, conventions (default)
- `security` — injection, secrets, auth, crypto, SSRF, supply chain
- `perf` — algorithmic complexity, N+1 I/O, allocations, hot-path overhead
- `api` — naming, breaking changes, surface area, type/schema discipline

Use `--aspects general,security,perf,api` (or `--aspects all`) for multi-angle review on changes that warrant it. Each aspect runs as its own parallel worker.

## The Workflow

For any non-trivial task:

1. **Recon first (cheap).** Unless you already have a recent recon for this project, run:
   ```bash
   scripts/gc-recon.sh --out tasks/_recon/recon.md
   ```
   Then read `tasks/_recon/recon.md` (≤3 KB). It gives you LAYERS, KEY_MODULES, CONVENTIONS, CHECK_COMMANDS, WATCH_OUT_FOR. **Do not read source files yourself** to learn the project.

2. **Plan.** Using the recon map, decide what to change. Identify file scopes that can run in parallel without overlap.

3. **Author prompts.** For each parallel unit, write a `*.prompt` file under `tasks/<batch-id>/`. Be specific:
   - Exact files the worker may create or modify.
   - Acceptance criteria as 2–4 bullets.
   - **Always include the project's check commands** from the recon map (e.g. "After editing, run `pnpm typecheck && pnpm test src/auth`. Report pass/fail in NOTES."). This is the quality guard.
   - References to existing files to mirror, by path.

4. **Dispatch with context.** Always pass the recon map as `--context-file` so workers know the conventions:
   ```bash
   scripts/gc-parallel.sh tasks/<batch-id> \
     --context-file tasks/_recon/recon.md \
     --max-parallel 4
   ```

5. **Read summaries only.** When the dispatcher returns, read `tasks/<batch-id>/*.summary` and `*.exitcode`. **Do not read `*.log` unless a worker failed.** Look for failed check commands in NOTES.

6. **Review (cheap).** Commit the batch's changes, then dispatch one or more reviewers:
   ```bash
   git add -A && git commit -m "batch <id>: <one-line>"
   # default: single general reviewer
   scripts/gc-review.sh
   # for security/perf-sensitive or API-changing batches: multi-angle
   scripts/gc-review.sh --aspects general,security,perf,api
   # autoloop: review → autofix → re-review until clean (or 3 iters)
   scripts/gc-review.sh --aspects all --until-clean \
     --check-cmd "pnpm typecheck && pnpm test" \
     --cwd <project-subdir-if-any>
   ```
   Read `tasks/review-*/<aspect>.summary` (one per aspect). If aggregated verdict is `clean`, move on. If `issues` or `blocking` and you didn't use `--until-clean`, dispatch a fix batch yourself — **do not read the diff** to triage; the reviewer's findings already cite `file:line`.

7. **Integrate.** Run any final cross-cutting checks (delegate that too if heavy). Repeat from step 2 until done.

8. **Report.** Summarize outcomes for the user in 1–3 sentences.

## Worker Prompt Authoring Rules

A good implementer prompt:

- Names the **exact files** the worker may create or modify, and forbids touching others.
- States the **acceptance criteria** in 2–4 bullets.
- **Specifies check commands** to run and report (typecheck / lint / test / build).
- Points to **existing files to mirror** by path, rather than re-explaining conventions (the recon map carries the rest).
- Tells the worker to **write code to disk, not into chat** (the preamble enforces this; reinforce in tricky cases).
- Avoids open-ended language ("make it better") — workers can't negotiate scope.

Bad prompt → silent failure, divergent style, or ballooning summary that costs you the tokens you tried to save.

## Parallelization Cheatsheet

| Situation | Run as |
|---|---|
| Implement N independent modules | N parallel implementers |
| Implement module + write its tests | 2 parallel (different file paths) |
| Refactor pattern across many files, disjoint | N parallel by file group |
| Implement → then integrate → then test | 3 sequential batches |
| Single tightly-coupled change | 1 worker (no parallelism gain) |
| Anything < ~30 lines and you already have full context | Just do it yourself; spawning a worker has overhead |

## Hard Constraints

- **Never read `tasks/<batch>/*.log`** unless `*.exitcode` is non-zero or the summary indicates failure. Logs are large by design.
- **Never read project source files yourself** to learn the codebase — that's recon's job. Exception: a single small file (<200 lines) you must edit by hand falls in your "do it yourself" bucket.
- **Never paste worker output verbatim** into your reply to the user. Summarize.
- **Never run a worker without a target file path** in its prompt. Vague workers produce sprawling output.
- **Always pass `--context-file`** when you have a recon map. Workers without context drift in style.
- **Trust but verify with a reviewer**, not with your own re-reading.
- **Git is your safety net**. Commit between batches so reviewers can run on focused diffs and so you can revert cheaply.

## Quick Commands

```bash
# Sanity-check the environment
scripts/gc-check.sh

# Recon — produce the project map (read this, not the source)
scripts/gc-recon.sh --out tasks/_recon/recon.md
scripts/gc-recon.sh "Focus on src/auth/* only"

# Implement — parallel batch with recon as context
scripts/gc-parallel.sh tasks/<batch-id> \
  --context-file tasks/_recon/recon.md \
  --max-parallel 4

# Resilient dispatch — retry on quota / 429 and fall back to a cheaper model
scripts/gc-parallel.sh tasks/<batch-id> \
  --context-file tasks/_recon/recon.md \
  --retries 2 --fallback-model gemini-3-flash-preview

# Review — audit the most recent commit
scripts/gc-review.sh                                    # general aspect only
scripts/gc-review.sh --aspects all                      # general + security + perf + api in parallel
scripts/gc-review.sh --aspects security,perf            # subset
scripts/gc-review.sh --range main..HEAD
scripts/gc-review.sh --staged
scripts/gc-review.sh --until-clean --max-iters 3 \
  --check-cmd "<typecheck && test command>" \
  --cwd <project-subdir>                                # autoloop: fix until clean

# Inspect token usage / estimated cost
scripts/gc-stats.sh                                     # last 24h
scripts/gc-stats.sh --since 7d --by model
scripts/gc-stats.sh --since-batch v04-b1 --by worker_type

# One-shot single worker
scripts/gc-dispatch.sh "Implement X in src/foo.ts ..." \
  --context-file tasks/_recon/recon.md
```

## v0.4 artifacts produced per worker

Each worker now leaves these files in its batch directory:

- `<id>.text`        — extracted natural-text response (the human surface)
- `<id>.log`         — raw JSON output from gemini (forensic only — DON'T read unless investigating a failure)
- `<id>.summary`     — STATUS/VERDICT block (the conductor surface)
- `<id>.exitcode`    — process exit code
- `<id>.status`      — `ok | partial | failed | ok-fallback | partial-fallback | unknown`
- `<id>.usage.json`  — per-worker token usage and timing
- `_batch.usage.json` — batch-level aggregate (read by `gc-stats.sh`)

The `-fallback` suffix on a status means the worker only succeeded after `--fallback-model` engaged. Treat it as success but log it — repeated fallbacks indicate the primary model is wrong-sized for the task.

## Gemini Rate-Limit Resilience (v0.6)

### How to handle paused workers

1. **New status**: `paused-quota` is NOT a failure. It means a worker hit a hard-rate-limit (Pro daily quota etc.) and was preserved for resumption. Treat it as "in-flight, awaiting quota reset".
2. **Resumption**:
   - Decision A: continue with other batches that don't depend on the paused work; resumed workers' artifacts will appear later.
   - Decision B: invoke `scripts/gc-resume-workers.sh tasks/<batch>` (or `--all`) to retry now (with `--force` if you want to skip the time check).
   - You generally do NOT need to invoke this manually — `scripts/gc-watch.sh` (if running) does it on a 5-minute cadence.
3. **Artifacts**: The `paused-quota` status persists in `<id>.status` file content, and `<id>.pause.json` carries the re-dispatch metadata. Once resumed successfully, those files are overwritten with the normal artifacts and the pause.json is archived as `<id>.pause.json.resumed-<ts>`.
4. **Exit code 4**: `gc-parallel.sh` (and downstream `gc-review.sh` autoloop) exits 4 when there are paused-but-no-failed workers. Don't treat exit 4 as a fatal error.

## Session Resume (v0.5)

### What you do at session start

- If `tasks/_session/state.md` exists, read it FIRST (before doing anything else, including reading user-supplied source files). It is your "where were we" briefing — generated automatically by gc-checkpoint.sh on each Stop event.
- If `tasks/_session/plan.md` exists, that's your active plan written by your previous self. Continue from the first unchecked `[ ]` item.
- If neither exists and the task is multi-step (3+ batches expected), draft `tasks/_session/plan.md` BEFORE dispatching the first batch.

### plan.md schema

A simple, pragmatic schema (no validator — Claude follows the convention):

```markdown
# Plan

Goal: <one-line>
Started: <YYYY-MM-DD>

Steps:
- [x] completed step
- [x] completed step
- [ ] current step
- [ ] future step

Notes:
- <freeform context for resume>
```

You update plan.md after each batch by checking `[x]` items and adding any new sub-steps that emerged.

### Auto-checkpoint on Stop

If the user has wired up the Stop hook (see `examples/stop-hook-snippet.json` and the install note in README), `tasks/_session/state.md` regenerates automatically on every turn end. You don't need to invoke `gc-checkpoint.sh` manually — but `gc-resume.sh` is yours to invoke whenever you want to take a fresh look.

### What the briefing contains

`gc-resume.sh` produces a markdown file with:
- Active goal (parsed from plan.md)
- Plan progress (full plan.md)
- Recent activity (last ~30 events with emoji and one-line summary)
- Recent commits (`git log --oneline -20`)
- Working tree (`git status --short`)
- Suggested next step (heuristic, e.g. "investigate failed worker in batch X" / "continue with first unchecked plan item")

### When the rate-limit hits Claude

If your session is interrupted by a Claude rate-limit pause:
1. Stop hook fires → state.md saves automatically.
2. The user opens a new session later.
3. The new "you" reads state.md and plan.md and resumes from the next unchecked step.
4. No special instruction from the user is required — the resume is mechanical.

If the Stop hook is NOT configured, the user can manually run `scripts/gc-resume.sh` between sessions to bridge the gap.

When the user says "use Conductor mode" or starts a session in this repo, this file is your standing instruction. Do not deviate without telling them.
