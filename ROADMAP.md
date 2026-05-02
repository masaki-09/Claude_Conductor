# Roadmap to v1.0.0

A simplified plan toward the official 1.0 release. Each minor version focuses on one theme; breaking changes are batched here so that 1.0 can lock the surface.

## Released

### v0.1 — Core dispatcher
- `gc-parallel.sh` parallel worker dispatch
- Worker preamble contract (STATUS / FILES / NOTES)
- Single-source-of-truth conductor manual (`CLAUDE.md`)

### v0.2 — Three-worker model
- `gc-recon.sh` (read-only project mapping)
- `gc-review.sh` (read-only diff audit)
- `--context-file` plumbing so workers stay aligned to project conventions

### v0.3 — Multi-aspect reviewers + autoloop
- Aspect reviewers: `general` / `security` / `perf` / `api`
- `--until-clean` autoloop (review → autofix → re-review)
- Model role separation (recon/review = pro, implementer = flash)

### v0.4 — Resilience + visibility
- Per-worker retry + quota-aware fallback model
- Token telemetry (`<id>.usage.json`, `_batch.usage.json`, `gc-stats.sh`)
- Diff-pack pre-build (one git diff shared across all aspect reviewers)

### v0.5 — Session checkpoint & rate-limit-safe resume (Claude side)
- Append-only `tasks/_session/events.jsonl`
- `gc-resume.sh` (briefing renderer) + `gc-checkpoint.sh` (Stop hook)
- `tasks/_session/plan.md` schema (Claude-authored, persists across sessions)
- v0.4.1 carryover: `_batch.usage.json` for single-worker batches; trap-based /tmp cleanup
- Concurrent-batch lockfile

### v0.6 — Gemini-side rate-limit resilience
- `paused-quota` status when hard-limit detected (TerminalQuotaError, multi-hour reset)
- `<id>.pause.json` carries re-dispatch metadata
- `gc-resume-workers.sh` (manual replay) + `gc-watch.sh` (always-on auto-resume)
- `gc-parallel.sh` exit code 4 = paused-only (distinct from 1 = failed)

## Planned

### v0.7 — Recon delta
**Theme**: cheap incremental project-map updates so long sessions don't re-scan from scratch.
- New `scripts/gc-recon-delta.sh`
- Recon map gets a `RECON_AT: <git-sha>` header
- Delta worker reads existing map + `git diff <sha>..HEAD` and emits an updated map
- Auto-trigger heuristic: if `RECON_AT` is more than N commits old, suggest delta

### v0.8 — Policy-driven reviewer (true read-only)
**Theme**: replace the `--mode yolo` + preamble no-write workaround with a Gemini Policy Engine declaration.
- New `prompts/reviewer-policy.json` (or `.yaml`) describing allowed tools (read_file, list_directory, shell read-only commands) and denied tools (write_file, edit_file, etc.)
- `gc-review.sh` switches to `--mode default --policy <path>`
- Workers cannot write even if they tried — defense-in-depth becomes structural

### v0.9 — Tests, CI, and OSS hygiene
**Theme**: prepare for public release.
- Smoke test harness (`tests/` + `scripts/gc-test.sh`)
- GitHub Actions CI: `bash -n` on all scripts, `gc-check.sh`, hello-batch dry-run
- `CHANGELOG.md` (one-line-per-tag style), `CONTRIBUTING.md`, ISSUE_TEMPLATE / PR_TEMPLATE
- Code style consistency pass (`shellcheck`, `pyright` on embedded python)
- `gc-stats` pricing constants moved to a sidecar JSON (easier to update without touching the script)

### v1.0.0 — Official release
**Theme**: stability guarantees and discoverability.
- API stability promise: no breaking changes to flag surfaces or file schemas after 1.0 without a major bump
- Comprehensive `examples/` (real-world demo: build a small CLI tool end-to-end with Conductor; add the demo to README quick start)
- Optional packaging: `brew` formula and/or `npm` install wrapper for one-line install
- Public announcement (blog post, repo unfreeze)
- Whatever feedback emerges from v0.7-v0.9 use is rolled in here

## Possibly later (v1.x)

- **Multi-project plan.md / events** — work on several projects from one session and keep them straight
- **Cross-model reviewer pool** — reviewer aspects pick the model best at each (e.g. security gets Claude via API, perf gets Gemini Pro)
- **Built-in MCP server** — surface Conductor as an MCP server so Claude Code can dispatch via tool calls instead of bash
- **Visual session timeline** — a small static HTML report of `events.jsonl` for human-friendly retrospectives

## Non-goals

- Web UI / dashboard. Conductor is a CLI tool; the events.jsonl is sufficient telemetry.
- Native Windows shell support. Git Bash / WSL is enough; bashism porting isn't worth the maintenance.
- Replacing Claude Code or Gemini CLI. Conductor coordinates them, not replaces.
