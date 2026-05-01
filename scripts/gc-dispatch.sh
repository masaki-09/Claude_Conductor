#!/usr/bin/env bash
# gc-dispatch.sh — One-shot single-worker convenience wrapper.
#
# Builds an ad-hoc batch directory, drops the given prompt as a single
# *.prompt file, and runs gc-parallel.sh on it. Useful when you only have
# one task but still want the same summary/log discipline.
#
# Usage:
#   scripts/gc-dispatch.sh "<prompt text>"             [opts...]
#   scripts/gc-dispatch.sh --id <id> --file <prompt>   [opts...]
#   echo "..." | scripts/gc-dispatch.sh --stdin        [opts...]
#
# Extra opts are forwarded to gc-parallel.sh (e.g. --model, --cwd, --include,
# --retries, --retry-on, --fallback-model).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ID=""
PROMPT_FILE=""
PROMPT_TEXT=""
FROM_STDIN=0
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --id)    ID="$2"; shift 2 ;;
    --file)  PROMPT_FILE="$2"; shift 2 ;;
    --stdin) FROM_STDIN=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    --max-parallel|--model|--cwd|--include|--preamble|--context-file|--mode|--retries|--retry-on|--fallback-model)
      PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --dry-run)
      PASSTHROUGH+=("$1"); shift ;;
    *)
      if [ -z "$PROMPT_TEXT" ] && [ "$FROM_STDIN" -eq 0 ] && [ -z "$PROMPT_FILE" ]; then
        PROMPT_TEXT="$1"; shift
      else
        echo "[gc-dispatch] unexpected arg: $1" >&2; exit 2
      fi ;;
  esac
done

if [ -n "$PROMPT_FILE" ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "[gc-dispatch] --file not found: $PROMPT_FILE" >&2
  exit 2
fi

[ -z "$ID" ] && ID="oneshot-$(date +%Y%m%d-%H%M%S)-$$"
BATCH_DIR="$REPO_ROOT/tasks/$ID"
mkdir -p "$BATCH_DIR"

OUT="$BATCH_DIR/$ID.prompt"
if [ "$FROM_STDIN" -eq 1 ]; then
  cat > "$OUT"
elif [ -n "$PROMPT_FILE" ]; then
  cp "$PROMPT_FILE" "$OUT"
elif [ -n "$PROMPT_TEXT" ]; then
  printf '%s\n' "$PROMPT_TEXT" > "$OUT"
else
  echo "[gc-dispatch] no prompt provided. Pass a string, --file, or --stdin." >&2
  exit 2
fi

echo "[gc-dispatch] batch dir: $BATCH_DIR"
exec "$SCRIPT_DIR/gc-parallel.sh" "$BATCH_DIR" "${PASSTHROUGH[@]}"
