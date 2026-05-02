#!/usr/bin/env bash
# gc-recon-delta.sh — Incremental recon script.
#
# Usage:
#   gc-recon-delta.sh                              # auto-detect tasks/_recon/recon.md, update in place
#   gc-recon-delta.sh --map <path>                 # explicit map path
#   gc-recon-delta.sh --out <path>                 # write to a different path (default: --map path)
#   gc-recon-delta.sh --since <sha>                # override the RECON_AT in the map
#   gc-recon-delta.sh --force                      # skip the staleness checks (refresh even on small diffs)
#   gc-recon-delta.sh --suggest-full               # if delta would touch >N files (default 30), exit 0
#   gc-recon-delta.sh --model <name>               # override delta worker model (default gemini-3-flash-preview)
#   gc-recon-delta.sh --retries N                  # per-worker retries on transient failures (passthrough)
#   gc-recon-delta.sh --retry-on PATTERN           # extra regex for retry trigger (passthrough)
#   gc-recon-delta.sh --fallback-model NAME        # final attempt model on persistent failure (passthrough)
#   gc-recon-delta.sh --dry-run                    # show what would happen, don't dispatch
#   gc-recon-delta.sh --help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/log-event.sh
. "$REPO_ROOT/lib/log-event.sh" 2>/dev/null || true

MAP_PATH="tasks/_recon/recon.md"
OUT_PATH=""
SINCE_SHA=""
FORCE=false
SUGGEST_FULL=false
MODEL="gemini-3-flash-preview"
DRY_RUN=false

RETRIES="1"
RETRY_ON=""
FALLBACK_MODEL="gemini-3-flash-preview"

while [ $# -gt 0 ]; do
  case "$1" in
    --map)          MAP_PATH="$2"; shift 2 ;;
    --out)          OUT_PATH="$2"; shift 2 ;;
    --since)        SINCE_SHA="$2"; shift 2 ;;
    --force)        FORCE=true; shift ;;
    --suggest-full) SUGGEST_FULL=true; shift ;;
    --model)        MODEL="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --retries)      RETRIES="$2"; shift 2 ;;
    --retry-on)     RETRY_ON="$2"; shift 2 ;;
    --fallback-model) FALLBACK_MODEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

PASSTHROUGH=("--retries" "$RETRIES")
[ -n "$RETRY_ON" ] && PASSTHROUGH+=("--retry-on" "$RETRY_ON")
[ -n "$FALLBACK_MODEL" ] && PASSTHROUGH+=("--fallback-model" "$FALLBACK_MODEL")

# 1. Resolve map path
if [ ! -f "$MAP_PATH" ]; then
  echo "no map at $MAP_PATH; run gc-recon.sh first" >&2
  exit 1
fi
OUT_PATH="${OUT_PATH:-$MAP_PATH}"

# 2. Parse RECON_AT and RECON_BRANCH
# Reading first ~3 lines
HEADER_LINES=$(head -n 3 "$MAP_PATH")
PARSED_SHA=$(echo "$HEADER_LINES" | grep "^RECON_AT:" | awk '{print $2}')
PARSED_BRANCH=$(echo "$HEADER_LINES" | grep "^RECON_BRANCH:" | awk '{print $2}')

if [ -z "$PARSED_SHA" ] || [ "$PARSED_SHA" = "no-git" ]; then
  echo "map has no RECON_AT — was it produced by gc-recon.sh v0.7+?" >&2
  exit 1
fi

# 3. Override SHA if --since is given
SINCE_SHA="${SINCE_SHA:-$PARSED_SHA}"

# 4. Verify branch
if git rev-parse --git-dir >/dev/null 2>&1; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  if [ "$CURRENT_BRANCH" != "$PARSED_BRANCH" ]; then
    echo "branch changed: map at $PARSED_BRANCH, working on $CURRENT_BRANCH — delta may not reflect a sensible diff" >&2
  fi
else
  echo "Error: Not a git repository." >&2
  exit 1
fi

# Verify SHA exists
if ! git rev-parse --verify "$SINCE_SHA" >/dev/null 2>&1; then
  echo "Error: SHA $SINCE_SHA not found in repository." >&2
  exit 1
fi

# 5. Compute diffs
# Use git diff <sha> (not <sha>..HEAD) to include working-tree changes
DIFF_NAME_STATUS=$(git diff --name-status "$SINCE_SHA")
DIFF_LOG=$(git log --oneline "$SINCE_SHA"..HEAD)
DIFF_SHORTSTAT=$(git diff --shortstat "$SINCE_SHA")
if [ -z "$DIFF_NAME_STATUS" ]; then
  FILES_CHANGED=0
else
  FILES_CHANGED=$(printf '%s' "$DIFF_NAME_STATUS" | grep -c '^')
fi

# 6. Suggest full recon
if [ "$SUGGEST_FULL" = true ] && [ "$FILES_CHANGED" -gt 30 ]; then
  echo "Delta would touch $FILES_CHANGED files (>30). Recommending full recon (scripts/gc-recon.sh) instead."
  exit 0
fi

# 7. Check if diff is empty
if [ "$FILES_CHANGED" -eq 0 ] && [ "$FORCE" = false ]; then
  echo "no changes since recon"
  exit 0
fi

# 8. Build delta task
TS=$(date +%Y%m%d-%H%M%S)
PID=$$
ID="recon-delta-$TS-$PID"
TASK_DIR="$REPO_ROOT/tasks/$ID"

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would create task dir: $TASK_DIR"
else
    mkdir -p "$TASK_DIR"
fi

# Strip headers from existing map
EXISTING_MAP_CONTENT=$(sed '1,3d' "$MAP_PATH")

PROMPT_BODY="Update the recon map to reflect changes since the prior recon.

## Existing map (provided as context)

$EXISTING_MAP_CONTENT

## Changes since RECON_AT ($SINCE_SHA)

### Changed files (git diff --name-status):
$DIFF_NAME_STATUS

### Commits in range:
$DIFF_LOG

### Diffstat:
$DIFF_SHORTSTAT

## Acceptance

Produce an UPDATED map in the same schema as the existing one (STATUS / PROJECT_KIND / ENTRYPOINTS / LAYERS / KEY_MODULES / CONVENTIONS / CHECK_COMMANDS / WATCH_OUT_FOR / OPEN_QUESTIONS).
- Add new files to ENTRYPOINTS / KEY_MODULES.
- Mark deletions: remove from KEY_MODULES; if a layer was emptied, remove from LAYERS.
- Refresh entries for modified files where the change is significant enough.
- LAYERS / CONVENTIONS / CHECK_COMMANDS usually unchanged unless added/removed/renamed.
- Stay within 3KB total.
- DO NOT include RECON_AT or RECON_BRANCH in your output — the script will inject them."

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would write delta.prompt to $TASK_DIR"
else
    printf "%s\n" "$PROMPT_BODY" > "$TASK_DIR/delta.prompt"
fi

# 9. Dispatch
PREAMBLE="$REPO_ROOT/prompts/recon-delta-preamble.md"
if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would dispatch: scripts/gc-parallel.sh $TASK_DIR --preamble $PREAMBLE --mode plan --model $MODEL --max-parallel 1 ${PASSTHROUGH[@]}"
    exit 0
fi

gc_log_event recon_delta_start sha_from="$SINCE_SHA" sha_to="$(git rev-parse HEAD)" files_changed="$FILES_CHANGED"

"$SCRIPT_DIR/gc-parallel.sh" "$TASK_DIR" \
  --preamble "$PREAMBLE" \
  --mode plan \
  --model "$MODEL" \
  --max-parallel 1 \
  "${PASSTHROUGH[@]}"
rc=$?

if [ $rc -ne 0 ]; then
    echo "gc-parallel.sh failed with exit code $rc" >&2
    gc_log_event recon_delta_end exit="$rc" map_path="$OUT_PATH"
    exit $rc
fi

# 10. After completion
if [ ! -f "$TASK_DIR/delta.summary" ]; then
    echo "Error: delta.summary not found in $TASK_DIR" >&2
    exit 1
fi

NEW_SHA=$(git rev-parse HEAD)
NEW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NEW_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Backup previous map if writing in place and it exists
if [ "$OUT_PATH" = "$MAP_PATH" ] && [ -f "$MAP_PATH" ]; then
    cp "$MAP_PATH" "${MAP_PATH}.previous"
fi

{
    echo "RECON_AT: $NEW_SHA $NEW_TS"
    echo "RECON_BRANCH: $NEW_BRANCH"
    echo
    cat "$TASK_DIR/delta.summary"
} > "$OUT_PATH"

gc_log_event recon_delta_end exit=0 map_path="$OUT_PATH"
echo "Recon map updated at $OUT_PATH"
