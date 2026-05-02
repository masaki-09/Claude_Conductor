#!/usr/bin/env bash
# gc-recon.sh — Dispatch a read-only recon worker that produces a structured
# project map for the Conductor to use as context for downstream batches.
#
# Usage:
#   scripts/gc-recon.sh                              # recon the whole project
#   scripts/gc-recon.sh "focus on the auth subsystem under src/auth/"
#   scripts/gc-recon.sh --file path/to/focus.txt
#   scripts/gc-recon.sh --out tasks/_recon/recon.md  # also copy result to a stable location
#
# Pass-through opts: --model, --cwd, --include, --retries, --retry-on, --fallback-model
#
# Result locations:
#   tasks/recon-<timestamp>/recon.summary           # the structured map (read this)
#   tasks/recon-<timestamp>/recon.log               # full output (do not read)
# If --out is given, the structured map is also copied to that path so it can
# be passed to gc-parallel.sh as --context-file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_ROOT/lib/log-event.sh" 2>/dev/null || true
PREAMBLE="$REPO_ROOT/prompts/recon-preamble.md"

OUT_PATH=""
PROMPT_FILE=""
PROMPT_TEXT=""
MODEL_OVERRIDE=""
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT_PATH="$2"; shift 2 ;;
    --file)  PROMPT_FILE="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --cwd|--include|--retries|--retry-on|--fallback-model)
      PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*)
      echo "[gc-recon] unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$PROMPT_TEXT" ] && [ -z "$PROMPT_FILE" ]; then
        PROMPT_TEXT="$1"; shift
      else
        echo "[gc-recon] unexpected arg: $1" >&2; exit 2
      fi ;;
  esac
done

if [ -n "$PROMPT_FILE" ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "[gc-recon] --file not found: $PROMPT_FILE" >&2
  exit 2
fi

ID="recon-$(date +%Y%m%d-%H%M%S)-$$"
RECON_MODEL="${MODEL_OVERRIDE:-gemini-3-pro-preview}"
gc_log_event recon_start \
  batch_id="$ID" \
  out_path="${OUT_PATH:-none}" \
  model="$RECON_MODEL"
BATCH_DIR="$REPO_ROOT/tasks/$ID"
mkdir -p "$BATCH_DIR"

OUT="$BATCH_DIR/recon.prompt"
{
  if [ -n "$PROMPT_FILE" ]; then
    cat "$PROMPT_FILE"
  elif [ -n "$PROMPT_TEXT" ]; then
    printf '%s\n' "$PROMPT_TEXT"
  else
    echo "Recon the entire project workspace. No focus area specified — produce a balanced map covering all top-level layers."
  fi
} > "$OUT"

echo "[gc-recon] batch dir: $BATCH_DIR (model: $RECON_MODEL)"
"$SCRIPT_DIR/gc-parallel.sh" "$BATCH_DIR" \
  --preamble "$PREAMBLE" \
  --mode plan \
  --model "$RECON_MODEL" \
  --max-parallel 1 \
  "${PASSTHROUGH[@]}"
rc=$?

if [ $rc -eq 0 ] && [ -n "$OUT_PATH" ] && [ -f "$BATCH_DIR/recon.summary" ]; then
  mkdir -p "$(dirname "$OUT_PATH")"
  cp "$BATCH_DIR/recon.summary" "$OUT_PATH"
  echo "[gc-recon] map copied to: $OUT_PATH"
fi

if [ $rc -eq 0 ]; then
  echo "[gc-recon] done. Read: $BATCH_DIR/recon.summary"
fi

gc_log_event recon_end \
  batch_id="$ID" \
  exit="$rc" \
  out_path="${OUT_PATH:-none}"

exit $rc
