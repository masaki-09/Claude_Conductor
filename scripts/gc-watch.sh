#!/usr/bin/env bash
# gc-watch.sh — Periodically resume paused-quota workers across all task directories.

set -uo pipefail

# ---------- defaults ----------
INTERVAL=300
ONCE=0
MAX_RUNTIME=0
QUIET=0
START_TIME=$(date +%s)
RUNNING=1
STOP_REASON=""

# ---------- locate repo root ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/log-event.sh
. "$REPO_ROOT/lib/log-event.sh" 2>/dev/null || true

RESUME_SCRIPT="$SCRIPT_DIR/gc-resume-workers.sh"

# ---------- helpers ----------
log() {
  if [ "$QUIET" -eq 0 ]; then
    echo "[gc-watch] $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"
  fi
}

log_stop() {
  local reason="${1:-sigterm}"
  if command -v gc_log_event >/dev/null; then
    gc_log_event watch_stop reason="$reason"
  fi
  if [ "$QUIET" -eq 0 ]; then
    echo "[gc-watch]                       stopped ($reason)"
  fi
}

show_help() {
  cat <<EOF
Usage: scripts/gc-watch.sh [options]

Options:
  --interval SECONDS   Poll every N seconds (default: 300)
  --once               Single sweep then exit
  --max-runtime SECS   Auto-exit after N seconds (default: 0 = forever)
  --quiet              Only log to events.jsonl, no stdout
  --foreground         Default behavior (stay in foreground)
  --help               Show this message
EOF
}

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --max-runtime)
      MAX_RUNTIME="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --foreground)
      # default behavior, no-op
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

# ---------- check requirements ----------
if [ ! -f "$RESUME_SCRIPT" ]; then
  echo "Error: $RESUME_SCRIPT not found. (Must be created by parallel worker)" >&2
  exit 2
fi

# ---------- signal handling ----------
trap 'RUNNING=0; STOP_REASON="sigint"' INT
trap 'RUNNING=0; STOP_REASON="sigterm"' TERM

# ---------- main loop ----------
if command -v gc_log_event >/dev/null; then
  gc_log_event watch_start interval="$INTERVAL" once="$ONCE"
fi

if [ "$QUIET" -eq 0 ]; then
  cat <<EOF
[gc-watch] watcher starting (interval=${INTERVAL}s, pid=$$)
[gc-watch] polling: $RESUME_SCRIPT
[gc-watch] logs:    ${REPO_ROOT}/tasks/_session/events.jsonl
EOF
fi

while [ "$RUNNING" -eq 1 ]; do
  # Check if max-runtime exceeded
  if [ "$MAX_RUNTIME" -gt 0 ]; then
    NOW=$(date +%s)
    if [ $((NOW - START_TIME)) -ge "$MAX_RUNTIME" ]; then
      log_stop "max_runtime"
      exit 0
    fi
  fi

  # 1. Dry run to count eligible
  ELIGIBLE_OUTPUT=$(bash "$RESUME_SCRIPT" --all --dry-run 2>&1) || true
  
  # Extract count. Expecting "[gc-resume-workers] eligible: N"
  N=$(echo "$ELIGIBLE_OUTPUT" | sed -n 's/^\[gc-resume-workers\] eligible: \([0-9]\+\)$/\1/p' | head -n 1)
  [[ -z "$N" ]] && N="0"
  
  NEXT_TS=""
  if [ "$ONCE" -eq 0 ]; then
    if NEXT_WAKE=$(date -u -d "@$(($(date +%s) + INTERVAL))" +%H:%M:%SZ 2>/dev/null); then
      NEXT_TS=" (next: $NEXT_WAKE)"
    fi
  fi

  if [ "$N" -gt 0 ]; then
    log "tick — $N paused workers eligible — resuming..."
    bash "$RESUME_SCRIPT" --all > /dev/null 2>&1
    RC=$?
    log "                      resume sweep finished (rc=$RC)"
    if [ $RC -ne 0 ]; then
      echo "[gc-watch] error: sweep failed with rc=$RC" >&2
    fi
  else
    log "tick — $N paused workers eligible$NEXT_TS"
  fi
  
  if command -v gc_log_event >/dev/null; then
    gc_log_event watch_tick eligible="$N"
  fi

  if [ "$ONCE" -eq 1 ]; then
    log_stop "once_done"
    exit 0
  fi

  # Sleep in 1s slices to be responsive to signals
  for (( i=0; i<INTERVAL; i++ )); do
    if [ "$RUNNING" -eq 0 ]; then break; fi
    sleep 1
    # Check max-runtime during sleep too
    if [ "$MAX_RUNTIME" -gt 0 ]; then
      NOW=$(date +%s)
      if [ $((NOW - START_TIME)) -ge "$MAX_RUNTIME" ]; then
        RUNNING=0
        log_stop "max_runtime"
        exit 0
      fi
    fi
  done
done

log_stop "$STOP_REASON"
exit 0
