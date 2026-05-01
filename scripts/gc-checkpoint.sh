#!/usr/bin/env bash
# scripts/gc-checkpoint.sh — Claude Code Stop-hook entry point.
#
# Wires gc-resume.sh into the Claude Code hook system. On every Stop event,
# this script silently regenerates tasks/_session/state.md so that on the
# NEXT session (after a rate-limit pause, manual stop, or normal close)
# the conductor can read state.md and resume without losing context.
#
# Usage in .claude/settings.json (see examples/stop-hook-snippet.json):
#   "hooks": {
#     "Stop": [{
#       "matcher": "*",
#       "hooks": [{ "type": "command", "command": "<repo>/scripts/gc-checkpoint.sh" }]
#     }]
#   }
#
# Hooks receive JSON on stdin from Claude Code. This script ignores that input
# and just runs gc-resume.sh in --quiet mode.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Drain hook input — we don't use it but Claude Code may pipe JSON to stdin.
if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi

# Best-effort: never block or fail the parent session.
"$SCRIPT_DIR/gc-resume.sh" --quiet 2>/tmp/gc-checkpoint-err.$$ || {
  echo "[gc-checkpoint] non-fatal: gc-resume.sh exited non-zero (see /tmp/gc-checkpoint-err.$$)" >&2
  exit 0
}

exit 0
