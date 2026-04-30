#!/usr/bin/env bash
# gc-check.sh — Sanity check the Conductor environment.

set -uo pipefail

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; }

fail=0

echo "Claude Conductor — environment check"
echo

# bash version
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "bash $BASH_VERSION"
else
  warn "bash $BASH_VERSION (4+ recommended for 'wait -n')"
fi

# gemini CLI
if command -v gemini >/dev/null 2>&1; then
  ver="$(gemini --version 2>/dev/null | tail -n1)"
  ok "gemini CLI present (version: ${ver:-unknown})"
else
  bad "gemini CLI not found in PATH — install from https://geminicli.com"
  fail=1
fi

# git
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  warn "git not found (recommended for safe batch-by-batch workflow)"
fi

# repo layout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
for f in CLAUDE.md prompts/worker-preamble.md scripts/gc-parallel.sh scripts/gc-dispatch.sh; do
  if [ -f "$REPO_ROOT/$f" ]; then ok "$f"; else bad "missing $f"; fail=1; fi
done

# scripts executable?
for s in scripts/gc-parallel.sh scripts/gc-dispatch.sh scripts/gc-check.sh; do
  if [ -x "$REPO_ROOT/$s" ]; then ok "$s is executable"
  else warn "$s not executable — run: chmod +x $s"
  fi
done

# probe gemini headless mode (very small ping; uses ~1 input token)
if command -v gemini >/dev/null 2>&1; then
  echo
  echo "Probing gemini headless mode (this calls the API)..."
  if echo "Reply with the single word: pong" | gemini -p "" -o text --skip-trust 2>/dev/null | grep -qi pong; then
    ok "gemini headless probe succeeded"
  else
    warn "gemini headless probe did not return 'pong' — check auth / model availability"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All required components present."
else
  echo "Some required components are missing — see fail entries above." >&2
  exit 1
fi
