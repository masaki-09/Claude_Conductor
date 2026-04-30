#!/usr/bin/env bash
# gc-parallel.sh — Dispatch a batch of Gemini CLI workers in parallel.
#
# Usage:
#   scripts/gc-parallel.sh <task-dir> [--max-parallel N] [--model NAME]
#                                     [--cwd PATH] [--include DIR[,DIR]]
#                                     [--preamble PATH] [--context-file PATH]
#                                     [--mode yolo|auto_edit|plan|default]
#                                     [--dry-run]
#
# <task-dir> must contain one or more *.prompt files. Each *.prompt becomes
# one worker. The basename (without .prompt) is the worker ID.
#
# For each worker <id>, this script writes:
#   <task-dir>/<id>.log        — full worker stdout+stderr (large; do NOT read by default)
#   <task-dir>/<id>.summary    — short tail used by the conductor
#   <task-dir>/<id>.exitcode   — process exit code as text
#   <task-dir>/<id>.status     — one-line status (ok|failed|timeout)
#
# Each worker's input is built as: <preamble> + <context-file?> + <task body>.
# This lets recon output be prepended automatically (see scripts/gc-recon.sh).
#
# Defaults:
#   max-parallel = 4
#   model        = (gemini default; usually gemini-2.5-pro)
#   preamble     = prompts/worker-preamble.md
#   context-file = (none)
#   mode         = yolo            (use 'plan' for read-only recon/review workers)

set -uo pipefail

# ---------- locate repo root ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PREAMBLE="$REPO_ROOT/prompts/worker-preamble.md"

# ---------- parse args ----------
TASK_DIR=""
MAX_PARALLEL=4
MODEL=""
WORKER_CWD=""
INCLUDE_DIRS=""
PREAMBLE_FILE=""
CONTEXT_FILE=""
MODE="yolo"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --cwd)          WORKER_CWD="$2"; shift 2 ;;
    --include)      INCLUDE_DIRS="$2"; shift 2 ;;
    --preamble)     PREAMBLE_FILE="$2"; shift 2 ;;
    --context-file) CONTEXT_FILE="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    -*)
      echo "[gc-parallel] unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$TASK_DIR" ]; then TASK_DIR="$1"; else
        echo "[gc-parallel] unexpected positional arg: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

[ -z "$PREAMBLE_FILE" ] && PREAMBLE_FILE="$DEFAULT_PREAMBLE"

if [ -z "$TASK_DIR" ]; then
  echo "[gc-parallel] usage: $0 <task-dir> [opts]" >&2
  exit 2
fi
if [ ! -d "$TASK_DIR" ]; then
  echo "[gc-parallel] task dir not found: $TASK_DIR" >&2
  exit 2
fi
if [ ! -f "$PREAMBLE_FILE" ]; then
  echo "[gc-parallel] preamble not found: $PREAMBLE_FILE" >&2
  exit 2
fi
if [ -n "$CONTEXT_FILE" ] && [ ! -f "$CONTEXT_FILE" ]; then
  echo "[gc-parallel] context file not found: $CONTEXT_FILE" >&2
  exit 2
fi
case "$MODE" in
  yolo|auto_edit|plan|default) ;;
  *) echo "[gc-parallel] invalid --mode: $MODE (yolo|auto_edit|plan|default)" >&2; exit 2 ;;
esac

# Cap parallelism to a sane range
if [ "$MAX_PARALLEL" -lt 1 ]; then MAX_PARALLEL=1; fi
if [ "$MAX_PARALLEL" -gt 12 ]; then MAX_PARALLEL=12; fi

# ---------- collect prompt files ----------
PROMPT_FILES=()
while IFS= read -r -d '' f; do
  PROMPT_FILES+=("$f")
done < <(find "$TASK_DIR" -maxdepth 1 -type f -name '*.prompt' -print0 | sort -z)

if [ "${#PROMPT_FILES[@]}" -eq 0 ]; then
  echo "[gc-parallel] no *.prompt files in $TASK_DIR" >&2
  exit 2
fi

echo "[gc-parallel] batch: $TASK_DIR"
echo "[gc-parallel] workers: ${#PROMPT_FILES[@]}, max-parallel: $MAX_PARALLEL, mode: $MODE${MODEL:+, model: $MODEL}${WORKER_CWD:+, cwd: $WORKER_CWD}${CONTEXT_FILE:+, context: $CONTEXT_FILE}"

if [ "$DRY_RUN" -eq 1 ]; then
  for f in "${PROMPT_FILES[@]}"; do echo "  would dispatch: $(basename "$f")"; done
  exit 0
fi

# ---------- worker function ----------
run_worker() {
  local prompt_file="$1"
  local id; id="$(basename "$prompt_file" .prompt)"
  local log_file="$TASK_DIR/$id.log"
  local summary_file="$TASK_DIR/$id.summary"
  local exitcode_file="$TASK_DIR/$id.exitcode"
  local status_file="$TASK_DIR/$id.status"

  # Build full prompt: preamble + (optional) context + task body
  local combined; combined="$(mktemp)"
  {
    cat "$PREAMBLE_FILE"
    echo
    if [ -n "$CONTEXT_FILE" ]; then
      echo "## Project context (from recon)"
      echo
      cat "$CONTEXT_FILE"
      echo
    fi
    echo "## Task"
    echo
    echo "TASK ID: $id"
    echo
    cat "$prompt_file"
  } > "$combined"

  # Build gemini command
  local gemini_args=(-p "" -o text --skip-trust --approval-mode "$MODE")
  if [ -n "$MODEL" ];        then gemini_args+=(-m "$MODEL"); fi
  if [ -n "$INCLUDE_DIRS" ]; then gemini_args+=(--include-directories "$INCLUDE_DIRS"); fi

  local pushd_dir="${WORKER_CWD:-$PWD}"

  echo "[gc-parallel] start  $id" >&2
  local rc=0
  (
    cd "$pushd_dir" || exit 99
    gemini "${gemini_args[@]}" < "$combined"
  ) > "$log_file" 2>&1 || rc=$?

  rm -f "$combined"
  echo "$rc" > "$exitcode_file"

  # Extract summary: prefer the marker block emitted by the preamble.
  # Implementers/recon use STATUS:; reviewer uses VERDICT:. Accept either.
  if grep -nE '^(STATUS|VERDICT):[[:space:]]' "$log_file" > /dev/null 2>&1; then
    awk '/^(STATUS|VERDICT):[[:space:]]/{p=1} p{print}' "$log_file" | tail -c 4096 > "$summary_file"
  else
    {
      echo "STATUS: unknown (no STATUS/VERDICT marker in worker output)"
      echo "--- log tail ---"
      tail -n 30 "$log_file"
    } > "$summary_file"
  fi

  if [ "$rc" -eq 0 ]; then
    # Map both schemas onto a single status vocabulary: ok / partial / failed.
    if   grep -qE '^STATUS:[[:space:]]*ok'        "$summary_file"; then echo "ok"      > "$status_file"
    elif grep -qE '^VERDICT:[[:space:]]*clean'    "$summary_file"; then echo "ok"      > "$status_file"
    elif grep -qE '^STATUS:[[:space:]]*partial'   "$summary_file"; then echo "partial" > "$status_file"
    elif grep -qE '^VERDICT:[[:space:]]*issues'   "$summary_file"; then echo "partial" > "$status_file"
    elif grep -qE '^STATUS:[[:space:]]*failed'    "$summary_file"; then echo "failed"  > "$status_file"
    elif grep -qE '^VERDICT:[[:space:]]*blocking' "$summary_file"; then echo "failed"  > "$status_file"
    else echo "unknown" > "$status_file"
    fi
  else
    echo "failed (exit=$rc)" > "$status_file"
  fi

  echo "[gc-parallel] done   $id (exit=$rc, status=$(cat "$status_file"))" >&2
}

# ---------- throttle loop ----------
running=0
for f in "${PROMPT_FILES[@]}"; do
  run_worker "$f" &
  running=$((running + 1))
  if [ "$running" -ge "$MAX_PARALLEL" ]; then
    if wait -n 2>/dev/null; then :; else wait; fi
    running=$((running - 1))
  fi
done
wait

# ---------- final report ----------
echo
echo "[gc-parallel] batch complete: $TASK_DIR"
fail_count=0
for f in "${PROMPT_FILES[@]}"; do
  id="$(basename "$f" .prompt)"
  status="$(cat "$TASK_DIR/$id.status" 2>/dev/null || echo unknown)"
  printf "  %-30s %s\n" "$id" "$status"
  case "$status" in ok) ;; *) fail_count=$((fail_count + 1)) ;; esac
done

if [ "$fail_count" -gt 0 ]; then
  echo "[gc-parallel] $fail_count worker(s) not ok — inspect the corresponding *.summary and only fall back to *.log if needed." >&2
  exit 1
fi
exit 0
