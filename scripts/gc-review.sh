#!/usr/bin/env bash
# gc-review.sh — Dispatch a read-only reviewer worker that audits a code change
# (typically the most recent batch's diff) and reports BLOCKERS / WARNINGS / NITS.
#
# Usage:
#   scripts/gc-review.sh                                  # review HEAD vs HEAD~1
#   scripts/gc-review.sh --range main..HEAD               # review a range
#   scripts/gc-review.sh --staged                         # review staged changes
#   scripts/gc-review.sh --file path/to/extra-context.md  # append extra task body
#   scripts/gc-review.sh "Verify acceptance: A, B, C"     # extra task body inline
#
# Pass-through opts: --model, --cwd, --include

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREAMBLE="$REPO_ROOT/prompts/reviewer-preamble.md"

RANGE=""
STAGED=0
PROMPT_FILE=""
PROMPT_TEXT=""
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --range)  RANGE="$2"; shift 2 ;;
    --staged) STAGED=1; shift ;;
    --file)   PROMPT_FILE="$2"; shift 2 ;;
    --model|--cwd|--include)
      PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*)
      echo "[gc-review] unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$PROMPT_TEXT" ] && [ -z "$PROMPT_FILE" ]; then
        PROMPT_TEXT="$1"; shift
      else
        echo "[gc-review] unexpected arg: $1" >&2; exit 2
      fi ;;
  esac
done

if [ -n "$PROMPT_FILE" ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "[gc-review] --file not found: $PROMPT_FILE" >&2
  exit 2
fi

# Determine what to review and how to describe it in the prompt
if [ "$STAGED" -eq 1 ]; then
  DIFF_CMD="git diff --staged"
  CHANGED_CMD="git diff --staged --name-only"
  SCOPE_DESC="the staged changes (run \`git diff --staged\`)"
elif [ -n "$RANGE" ]; then
  DIFF_CMD="git diff $RANGE"
  CHANGED_CMD="git diff --name-only $RANGE"
  SCOPE_DESC="the diff of \`$RANGE\` (run \`git diff $RANGE\`)"
else
  DIFF_CMD="git diff HEAD~1..HEAD"
  CHANGED_CMD="git diff --name-only HEAD~1..HEAD"
  SCOPE_DESC="the most recent commit (run \`git diff HEAD~1..HEAD\`)"
fi

ID="review-$(date +%Y%m%d-%H%M%S)-$$"
BATCH_DIR="$REPO_ROOT/tasks/$ID"
mkdir -p "$BATCH_DIR"

OUT="$BATCH_DIR/review.prompt"
{
  echo "Review $SCOPE_DESC."
  echo
  echo "First, list the changed files with: \`$CHANGED_CMD\`"
  echo "Then, read the full diff with: \`$DIFF_CMD\`"
  echo "Open the changed files as needed for surrounding context. Then produce the verdict in the schema specified in the preamble."
  echo
  if [ -n "$PROMPT_FILE" ]; then
    echo "Additional context / acceptance criteria:"
    echo
    cat "$PROMPT_FILE"
  elif [ -n "$PROMPT_TEXT" ]; then
    echo "Additional context / acceptance criteria:"
    echo
    printf '%s\n' "$PROMPT_TEXT"
  fi
} > "$OUT"

echo "[gc-review] batch dir: $BATCH_DIR"
"$SCRIPT_DIR/gc-parallel.sh" "$BATCH_DIR" \
  --preamble "$PREAMBLE" \
  --mode plan \
  --max-parallel 1 \
  "${PASSTHROUGH[@]}"
rc=$?

if [ $rc -eq 0 ]; then
  echo "[gc-review] done. Read: $BATCH_DIR/review.summary"
fi
exit $rc
