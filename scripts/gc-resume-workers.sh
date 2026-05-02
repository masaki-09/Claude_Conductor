#!/usr/bin/env bash
# gc-resume-workers.sh — Re-dispatch paused-quota workers whose reset window has passed.
#
# Usage:
#   scripts/gc-resume-workers.sh <task-dir>             # resume eligible paused workers in this batch
#   scripts/gc-resume-workers.sh --all                  # scan all tasks/*/ for paused workers
#   scripts/gc-resume-workers.sh --dry-run <task-dir>   # list what would be resumed and why
#   scripts/gc-resume-workers.sh --force <task-dir>     # ignore estimated_resume_at; try now
#   scripts/gc-resume-workers.sh --help

set -uo pipefail

# ---------- locate repo root ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
# shellcheck source=../lib/log-event.sh
. "$REPO_ROOT/lib/log-event.sh" 2>/dev/null || true

usage() {
  cat <<EOF
Usage: scripts/gc-resume-workers.sh [OPTIONS] [TASK_DIR]

Re-dispatches 'paused-quota' workers whose reset window has passed.

Options:
  --all                  Scan all tasks/*/ for paused workers
  --dry-run              List what would be resumed and why, without acting
  --force                Ignore estimated_resume_at; try now
  --help                 Show this help

Examples:
  scripts/gc-resume-workers.sh tasks/v06-b1
  scripts/gc-resume-workers.sh --all
  scripts/gc-resume-workers.sh --dry-run tasks/v06-b1
EOF
}

ALL=false
DRY_RUN=false
FORCE=false
TASK_DIR_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) 
      if [[ -z "$TASK_DIR_ARG" ]]; then
        TASK_DIR_ARG="$1"
      else
        echo "Too many arguments: $1" >&2
        usage; exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$ALL" == "false" && -z "$TASK_DIR_ARG" ]]; then
  echo "Error: Must specify a task directory or --all." >&2
  usage; exit 1
fi

DIRS=()
if [[ "$ALL" == "true" ]]; then
  # Use nullglob to handle case where no dirs exist
  shopt -s nullglob
  for d in "$REPO_ROOT"/tasks/*/; do
    DIRS+=( "$d" )
  done
  shopt -u nullglob
else
  if [[ ! -d "$TASK_DIR_ARG" ]]; then
    echo "Error: Directory not found: $TASK_DIR_ARG" >&2
    exit 1
  fi
  DIRS+=( "$(cd "$TASK_DIR_ARG" && pwd)/" )
fi

PAUSE_FILES=()
shopt -s nullglob
for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  matches=( "$d"*.pause.json )
  PAUSE_FILES+=( "${matches[@]}" )
done
shopt -u nullglob

if [[ ${#PAUSE_FILES[@]} -eq 0 ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[gc-resume-workers] eligible: 0"
  else
    echo "no paused workers"
  fi
  exit 0
fi

RESUME_RESULTS=()
ANY_HIT_HARD_LIMIT=false
PROCESSED_COUNT=0

TEMP_TASK_DIR=""
if [[ "$DRY_RUN" == "false" ]]; then
  TEMP_TASK_DIR="$REPO_ROOT/tasks/_resume-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$TEMP_TASK_DIR"
fi

for pause_json in "${PAUSE_FILES[@]}"; do
  # Use python to check status and eligibility in one go
  JSON_DATA=$(python -c '
import json, sys, os, time
pause_file = sys.argv[1]
force = sys.argv[2].lower() == "true"
try:
    with open(pause_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
wid = data.get("id")
tdir = data.get("task_dir")
if not wid or not tdir:
    sys.exit(2)
status_f = os.path.join(tdir, f"{wid}.status")
try:
    with open(status_f, "r", encoding="utf-8") as f:
        status = f.read().strip()
    if status != "paused-quota":
        sys.exit(3)
except Exception:
    sys.exit(3)
est = data.get("estimated_resume_at")
eligible = force or not est or est == "null"
if not eligible:
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    eligible = now >= est
res = {
    "eligible": eligible,
    "id": wid,
    "batch_id": data.get("batch_id"),
    "model": data.get("model"),
    "mode": data.get("mode"),
    "prompt_file": data.get("prompt_file"),
    "preamble_file": data.get("preamble_file"),
    "context_file": data.get("context_file"),
    "cwd": data.get("cwd"),
    "include_dirs": data.get("include_dirs"),
    "task_dir": tdir,
    "estimated": est
}
print(json.dumps(res))
' "$pause_json" "$FORCE" 2>/dev/null)
  
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 2 ]]; then
    echo "Warning: Malformed or missing pause file: $pause_json" >&2
    continue
  elif [[ $EXIT_CODE -eq 3 ]]; then
    continue # Already resumed or status changed
  fi

  PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
  
  # Export variables from JSON
  RES_ELIGIBLE="" RES_ID="" RES_BATCH_ID="" RES_MODEL="" RES_MODE=""
  RES_PROMPT_FILE="" RES_PREAMBLE_FILE="" RES_CONTEXT_FILE=""
  RES_CWD="" RES_INCLUDE_DIRS="" RES_TASK_DIR="" RES_ESTIMATED=""
  
  eval "$(echo "$JSON_DATA" | python -c '
import json, sys
d = json.load(sys.stdin)
for k, v in d.items():
    val = "" if v is None or v == "null" else str(v)
    print(f"RES_{k.upper()}={json.dumps(val)}")
')"

  if [[ "$RES_ELIGIBLE" == "False" ]]; then
    RESUME_RESULTS+=("  $RES_BATCH_ID/$RES_ID     not yet (resume at $RES_ESTIMATED)")
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  WOULD resume $RES_BATCH_ID/$RES_ID (model=$RES_MODEL)"
    RESUME_RESULTS+=("  $RES_BATCH_ID/$RES_ID     WOULD resume")
    continue
  fi

  # Resumption logic: delegate to gc-parallel.sh via temp task dir
  WORKER_TEMP_DIR="$TEMP_TASK_DIR/$RES_ID"
  mkdir -p "$WORKER_TEMP_DIR"
  
  # Ensure we have the prompt
  if [[ ! -f "$RES_PROMPT_FILE" ]]; then
    echo "Error: Prompt file not found for $RES_ID: $RES_PROMPT_FILE" >&2
    RESUME_RESULTS+=("  $RES_BATCH_ID/$RES_ID     failed (missing prompt)")
    continue
  fi
  cp "$RES_PROMPT_FILE" "$WORKER_TEMP_DIR/$RES_ID.prompt"
  
  # Preamble override
  if [[ -n "$RES_PREAMBLE_FILE" && -f "$RES_PREAMBLE_FILE" ]]; then
    cp "$RES_PREAMBLE_FILE" "$WORKER_TEMP_DIR/$RES_ID.preamble.md"
  fi

  # Prepare args
  PARALLEL_ARGS=( "$WORKER_TEMP_DIR" "--model" "$RES_MODEL" "--mode" "$RES_MODE" )
  [[ -n "$RES_CONTEXT_FILE" ]] && PARALLEL_ARGS+=( "--context-file" "$RES_CONTEXT_FILE" )
  [[ -n "$RES_CWD" ]] && PARALLEL_ARGS+=( "--cwd" "$RES_CWD" )
  [[ -n "$RES_INCLUDE_DIRS" ]] && PARALLEL_ARGS+=( "--include" "$RES_INCLUDE_DIRS" )

  # Execute
  GC_BATCH_ID_OVERRIDE="$RES_BATCH_ID" "$REPO_ROOT/scripts/gc-parallel.sh" "${PARALLEL_ARGS[@]}" >/dev/null 2>&1
  RES_RC=$?
  
  NEW_STATUS="unknown"
  [[ -f "$WORKER_TEMP_DIR/$RES_ID.status" ]] && NEW_STATUS=$(cat "$WORKER_TEMP_DIR/$RES_ID.status")

  # Transfer results back
  for ext in log summary exitcode status text usage.json; do
    if [[ -f "$WORKER_TEMP_DIR/$RES_ID.$ext" ]]; then
      cp "$WORKER_TEMP_DIR/$RES_ID.$ext" "$RES_TASK_DIR/"
    fi
  done
  
  # BLOCKER 1: Handle re-pause vs completion
  if [[ -f "$WORKER_TEMP_DIR/$RES_ID.pause.json" ]]; then
    # Re-paused: copy new pause.json back, overwrite original, DO NOT archive
    cp "$WORKER_TEMP_DIR/$RES_ID.pause.json" "$pause_json"
  else
    # Completed (or failed without re-pause): archive original
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    mv "$pause_json" "$pause_json.resumed-$TIMESTAMP"
  fi

  # Telemetry
  gc_log_event worker_resumed batch_id="$RES_BATCH_ID" worker_id="$RES_ID" exit="$RES_RC" status="$NEW_STATUS"

  RESUME_RESULTS+=("  $RES_BATCH_ID/$RES_ID     resumed (status: $NEW_STATUS)")
  
  [[ "$NEW_STATUS" == "paused-quota" ]] && ANY_HIT_HARD_LIMIT=true
done

# Final Summary Table
if [[ "$PROCESSED_COUNT" -gt 0 ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    ELIGIBLE_COUNT=0
    for res in "${RESUME_RESULTS[@]}"; do
      [[ "$res" == *"WOULD resume"* ]] && ELIGIBLE_COUNT=$((ELIGIBLE_COUNT + 1))
    done
    echo "[gc-resume-workers] eligible: $ELIGIBLE_COUNT"
  fi

  echo "[gc-resume-workers] processed $PROCESSED_COUNT paused worker(s):"
  for line in "${RESUME_RESULTS[@]}"; do
    echo "$line"
  done
fi

# NIT 6: Cleanup temp dir
if [[ -n "$TEMP_TASK_DIR" && -d "$TEMP_TASK_DIR" ]]; then
  rm -rf "$TEMP_TASK_DIR"
fi

# Exit code: 0 if at least one resumed successfully OR all were "not yet eligible".
# Exit 1 if a re-attempted worker hit another hard-limit (paused again).
if [[ "$ANY_HIT_HARD_LIMIT" == "true" ]]; then
  exit 1
fi

exit 0
