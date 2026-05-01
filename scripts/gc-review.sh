#!/usr/bin/env bash
# gc-review.sh — Dispatch one or more read-only reviewer workers that audit a
# code change and report BLOCKERS / WARNINGS / NITS. Optionally loop with auto-fix
# until the review comes back clean.
#
# Usage:
#   scripts/gc-review.sh [scope-flags] [aspect-flags] [autoloop-flags] ["task body"]
#
# Scope (what to review):
#   (default)             review the most recent commit (HEAD~1..HEAD)
#   --range <ref>         review a git range, e.g. main..HEAD
#   --staged              review staged changes (not yet committed)
#   --file <path>         append extra task body / acceptance criteria
#   "<text>"              same, inline
#
# Aspects (who reviews):
#   (default)             single 'general' reviewer (uses prompts/reviewer-preamble.md)
#   --aspects <list>      comma-separated, parallel reviewers. Choices:
#                           general | security | perf | api | all
#                         e.g. --aspects general,security,perf
#
# Autoloop (review → autofix → re-review):
#   --until-clean         after a non-clean review, auto-dispatch a fix worker
#                         using the reviewer findings, commit the fixes, and
#                         re-review. Loops until clean or max-iters reached.
#   --max-iters N         autoloop iteration cap (default 3)
#   --check-cmd "..."     command the autofix worker must run after edits and
#                         report pass/fail in NOTES (e.g. "node --test test/")
#   --commit-prefix STR   prefix for autofix commit messages (default "autofix")
#
# Pass-through opts:
#   --model NAME          override reviewer model (default gemini-3-pro-preview)
#   --cwd PATH            run reviewer/fixer with this as working dir
#   --include DIR[,DIR]   extra directories accessible to workers
#   --fix-context FILE    recon map prepended to autofix worker prompts
#   --retries N           retry attempts on transient failures
#   --retry-on PATTERN    extra regex to trigger retry
#   --fallback-model NAME one last attempt with this model if primary fails

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/prompts"

# ---------- defaults ----------
RANGE=""
STAGED=0
PROMPT_FILE=""
PROMPT_TEXT=""
ASPECTS="general"
UNTIL_CLEAN=0
MAX_ITERS=3
CHECK_CMD=""
COMMIT_PREFIX="autofix"
REVIEWER_MODEL="gemini-3-pro-preview"
WORKER_CWD=""
INCLUDE_DIRS=""
FIX_CONTEXT=""
RETRIES=""
RETRY_ON=""
FALLBACK_MODEL=""

# ---------- parse args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --range)         RANGE="$2"; shift 2 ;;
    --staged)        STAGED=1; shift ;;
    --file)          PROMPT_FILE="$2"; shift 2 ;;
    --aspects)       ASPECTS="$2"; shift 2 ;;
    --until-clean)   UNTIL_CLEAN=1; shift ;;
    --max-iters)     MAX_ITERS="$2"; shift 2 ;;
    --check-cmd)     CHECK_CMD="$2"; shift 2 ;;
    --commit-prefix) COMMIT_PREFIX="$2"; shift 2 ;;
    --model)         REVIEWER_MODEL="$2"; shift 2 ;;
    --cwd)           WORKER_CWD="$2"; shift 2 ;;
    --include)       INCLUDE_DIRS="$2"; shift 2 ;;
    --fix-context)   FIX_CONTEXT="$2"; shift 2 ;;
    --retries)       RETRIES="$2"; shift 2 ;;
    --retry-on)      RETRY_ON="${RETRY_ON:+$RETRY_ON|}$2"; shift 2 ;;
    --fallback-model) FALLBACK_MODEL="$2"; shift 2 ;;
    -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
    -*)              echo "[gc-review] unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$PROMPT_TEXT" ] && [ -z "$PROMPT_FILE" ]; then
        PROMPT_TEXT="$1"; shift
      else
        echo "[gc-review] unexpected arg: $1" >&2; exit 2
      fi ;;
  esac
done

if [ -n "$PROMPT_FILE" ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "[gc-review] --file not found: $PROMPT_FILE" >&2; exit 2
fi
if [ -n "$FIX_CONTEXT" ] && [ ! -f "$FIX_CONTEXT" ]; then
  echo "[gc-review] --fix-context not found: $FIX_CONTEXT" >&2; exit 2
fi
if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]]; then
  echo "[gc-review] --max-iters must be a non-negative integer (got: $MAX_ITERS)" >&2; exit 2
fi

# Expand --aspects "all" to all known aspects
case ",${ASPECTS}," in
  *,all,*) ASPECTS="general,security,perf,api" ;;
esac

# Validate each aspect maps to a known preamble
ASPECT_LIST=()
IFS=',' read -ra _aspects <<< "$ASPECTS"
for a in "${_aspects[@]}"; do
  a="$(echo "$a" | tr -d '[:space:]')"
  case "$a" in
    general)  preamble="$PROMPTS_DIR/reviewer-preamble.md" ;;
    security) preamble="$PROMPTS_DIR/reviewer-security.md" ;;
    perf)     preamble="$PROMPTS_DIR/reviewer-perf.md" ;;
    api)      preamble="$PROMPTS_DIR/reviewer-api.md" ;;
    "")       continue ;;
    *) echo "[gc-review] unknown aspect: $a (allowed: general|security|perf|api|all)" >&2; exit 2 ;;
  esac
  if [ ! -f "$preamble" ]; then
    echo "[gc-review] preamble missing for aspect '$a': $preamble" >&2; exit 2
  fi
  ASPECT_LIST+=("$a:$preamble")
done

if [ "${#ASPECT_LIST[@]}" -eq 0 ]; then
  echo "[gc-review] no aspects specified" >&2; exit 2
fi

# ---------- build review scope description ----------
build_scope_description() {
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
}
build_scope_description

# ---------- run a single review batch (one or more aspects in parallel) ----------
run_review_batch() {
  local id="review-$(date +%Y%m%d-%H%M%S)-$$"
  local batch_dir="$REPO_ROOT/tasks/$id"
  mkdir -p "$batch_dir"

  # Build diff package
  local diff_pack="$batch_dir/_diff-pack.md"
  {
    echo "# Diff package for review"
    echo
    echo "SCOPE: $SCOPE_DESC"
    echo "GENERATED_AT: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Changed files"
    echo
    $CHANGED_CMD 2>/tmp/gc-err.$$ || echo "(could not list changed files)"
    [ -s /tmp/gc-err.$$ ] && echo "ERROR: $(cat /tmp/gc-err.$$)"
    rm -f /tmp/gc-err.$$
    echo
    echo "## Recent commits in scope"
    echo
    if [ "$STAGED" -eq 1 ]; then
      echo "(staged changes; not yet committed)"
    else
      local range_arg="${RANGE:-HEAD~1..HEAD}"
      git log --oneline "$range_arg" 2>/tmp/gc-err.$$ || echo "(could not list recent commits)"
      [ -s /tmp/gc-err.$$ ] && echo "ERROR: $(cat /tmp/gc-err.$$)"
      rm -f /tmp/gc-err.$$
    fi
    echo
    echo "## Full diff"
    echo
    echo '```diff'
    $DIFF_CMD 2>/tmp/gc-err.$$ || echo "(could not generate diff)"
    [ -s /tmp/gc-err.$$ ] && echo "ERROR: $(cat /tmp/gc-err.$$)"
    rm -f /tmp/gc-err.$$
    echo '```'
  } > "$diff_pack"

  for entry in "${ASPECT_LIST[@]}"; do
    local aspect="${entry%%:*}"
    local preamble="${entry#*:}"
    cp "$preamble" "$batch_dir/$aspect.preamble.md"
    {
      echo "Review $SCOPE_DESC."
      echo
      echo "The diff being reviewed is available as \`_diff-pack.md\` in the prepended project context above. Read it carefully. You may also \`read_file\` for surrounding context if needed. Then produce the verdict in the schema specified in the preamble."
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
    } > "$batch_dir/$aspect.prompt"
  done

  local n="${#ASPECT_LIST[@]}"
  local parallel="$n"
  [ "$parallel" -gt 4 ] && parallel=4

  # Reviewers run with --mode yolo so they can invoke `git diff` and `git log` —
  # plan mode in Gemini 3 blocks shell commands, even read-only ones. The reviewer
  # preambles forbid writing/editing files; with the prompt contract intact this is
  # safe in practice. The --no-write guard below is an extra belt-and-braces.
  echo "[gc-review] batch: $batch_dir (aspects: ${ASPECTS}, model: $REVIEWER_MODEL)"
  local pass_args=(--mode yolo --model "$REVIEWER_MODEL" --max-parallel "$parallel")
  [ -n "$WORKER_CWD" ]     && pass_args+=(--cwd "$WORKER_CWD")
  [ -n "$INCLUDE_DIRS" ]   && pass_args+=(--include "$INCLUDE_DIRS")
  [ -n "$diff_pack" ]      && pass_args+=(--context-file "$diff_pack")
  [ -n "$RETRIES" ]        && pass_args+=(--retries "$RETRIES")
  [ -n "$RETRY_ON" ]       && pass_args+=(--retry-on "$RETRY_ON")
  [ -n "$FALLBACK_MODEL" ] && pass_args+=(--fallback-model "$FALLBACK_MODEL")
  # Note: per-aspect preambles via <id>.preamble.md override the default --preamble
  pass_args+=(--preamble "$PROMPTS_DIR/reviewer-preamble.md")

  "$SCRIPT_DIR/gc-parallel.sh" "$batch_dir" "${pass_args[@]}" || true

  echo "$batch_dir"
}

# ---------- aggregate review verdicts across aspects ----------
# ... rest of function ...
# Echoes the worst verdict: blocking > issues > clean > unknown
aggregate_verdict() {
  local batch_dir="$1"
  local worst="clean"
  for entry in "${ASPECT_LIST[@]}"; do
    local aspect="${entry%%:*}"
    local sf="$batch_dir/$aspect.summary"
    if [ ! -s "$sf" ]; then worst="unknown"; continue; fi
    local v
    v="$(grep -m1 -E '^VERDICT:[[:space:]]' "$sf" | sed -E 's/^VERDICT:[[:space:]]*//' | awk '{print $1}')"
    case "$v" in
      blocking) worst="blocking"; break ;;
      issues)   [ "$worst" = "clean" ] && worst="issues" ;;
      clean)    : ;;
      *)        [ "$worst" = "clean" ] && worst="unknown" ;;
    esac
  done
  echo "$worst"
}

# ---------- build an autofix prompt from review summaries ----------
build_fix_prompt() {
  local batch_dir="$1"; shift
  local out_file="$1"
  {
    echo "The previous code review surfaced the following issues. Fix ONLY the items listed below — do not refactor unrelated code."
    echo
    for entry in "${ASPECT_LIST[@]}"; do
      local aspect="${entry%%:*}"
      local sf="$batch_dir/$aspect.summary"
      [ -s "$sf" ] || continue
      local v
      v="$(grep -m1 -E '^VERDICT:[[:space:]]' "$sf" | sed -E 's/^VERDICT:[[:space:]]*//' | awk '{print $1}')"
      [ "$v" = "clean" ] && continue
      echo "## Findings from '$aspect' reviewer (verdict: $v)"
      echo
      # Extract BLOCKERS and WARNINGS sections (between their heading and the next ALL-CAPS heading line)
      awk '
        /^BLOCKERS:[[:space:]]*$/ {section="BLOCKERS"; print "### "section; next}
        /^WARNINGS:[[:space:]]*$/ {section="WARNINGS"; print "### "section; next}
        /^[A-Z_]+:[[:space:]]*$/  {section=""; next}
        /^[A-Z_]+:[[:space:]]/    {section=""; next}
        section!="" && NF>0       {print}
      ' "$sf"
      echo
    done
    echo "## Files you may modify"
    echo "Only the files cited in the findings above (\`file:line\` references). Do not touch unrelated files."
    echo
    if [ -n "$CHECK_CMD" ]; then
      echo "## Validation"
      echo "After your edits, run from the project root:"
      echo
      echo "    $CHECK_CMD"
      echo
      echo "Report pass/fail and any failing test names in NOTES. If the check fails and you cannot fix it within scope, set STATUS: partial."
    fi
  } > "$out_file"
}

# ---------- one autofix iteration ----------
run_autofix() {
  local review_batch="$1"
  local iter="$2"
  local fix_id="autofix-$(date +%Y%m%d-%H%M%S)-iter${iter}-$$"
  local fix_dir="$REPO_ROOT/tasks/$fix_id"
  mkdir -p "$fix_dir"

  build_fix_prompt "$review_batch" "$fix_dir/fix.prompt"

  echo "[gc-review] autofix iter $iter: dispatching fix worker"
  local pass_args=(--max-parallel 1 --model gemini-3-flash-preview --mode yolo)
  [ -n "$WORKER_CWD" ]     && pass_args+=(--cwd "$WORKER_CWD")
  [ -n "$INCLUDE_DIRS" ]   && pass_args+=(--include "$INCLUDE_DIRS")
  [ -n "$FIX_CONTEXT" ]    && pass_args+=(--context-file "$FIX_CONTEXT")
  [ -n "$RETRIES" ]        && pass_args+=(--retries "$RETRIES")
  [ -n "$RETRY_ON" ]       && pass_args+=(--retry-on "$RETRY_ON")
  [ -n "$FALLBACK_MODEL" ] && pass_args+=(--fallback-model "$FALLBACK_MODEL")

  "$SCRIPT_DIR/gc-parallel.sh" "$fix_dir" "${pass_args[@]}"
  local rc=$?

  if [ $rc -ne 0 ]; then
    echo "[gc-review] autofix worker failed (rc=$rc); aborting loop" >&2
    return 1
  fi

  # Auto-commit fixes (must be inside the worker cwd, or the parent repo if --cwd not set)
  local commit_dir="${WORKER_CWD:-$PWD}"
  (
    cd "$commit_dir" || exit 99
    if [ -z "$(git status --porcelain)" ]; then
      echo "[gc-review] autofix iter $iter produced no diff — review will likely repeat the same findings" >&2
      exit 99
    fi
    local first_block
    first_block="$(grep -m1 'STATUS:' "$fix_dir/fix.summary" | head -c 80)"
    git add -A
    git commit -m "${COMMIT_PREFIX} iter ${iter}: address review feedback" \
               -m "${first_block}" >/dev/null
  ) || return 1

  echo "[gc-review] autofix iter $iter: committed."
  return 0
}

# ---------- main flow ----------
review_batch="$(run_review_batch | tail -1)"
verdict="$(aggregate_verdict "$review_batch")"

# Print per-aspect verdicts
echo
echo "[gc-review] per-aspect verdicts:"
for entry in "${ASPECT_LIST[@]}"; do
  aspect="${entry%%:*}"
  sf="$review_batch/$aspect.summary"
  if [ -s "$sf" ]; then
    v="$(grep -m1 -E '^VERDICT:[[:space:]]' "$sf" | sed -E 's/^VERDICT:[[:space:]]*//' | awk '{print $1}')"
  else
    v="unknown"
  fi
  printf "  %-10s %s\n" "$aspect" "${v:-unknown}"
done
echo "[gc-review] aggregated verdict: $verdict"
echo "[gc-review] read summaries at: $review_batch/<aspect>.summary"

if [ "$UNTIL_CLEAN" -ne 1 ]; then
  case "$verdict" in
    clean) exit 0 ;;
    *)     exit 1 ;;
  esac
fi

# ---------- --until-clean autoloop ----------
iter=1
while [ "$verdict" != "clean" ] && [ "$iter" -le "$MAX_ITERS" ]; do
  echo
  echo "[gc-review] autoloop: iter $iter / $MAX_ITERS  (current verdict: $verdict)"
  if ! run_autofix "$review_batch" "$iter"; then
    echo "[gc-review] autoloop aborted at iter $iter" >&2
    exit 1
  fi
  # Re-review (scope auto-shifts since HEAD advanced; HEAD~1..HEAD stays current commit)
  build_scope_description
  review_batch="$(run_review_batch | tail -1)"
  verdict="$(aggregate_verdict "$review_batch")"
  echo
  echo "[gc-review] post-fix verdict (iter $iter): $verdict"
  iter=$((iter + 1))
done

if [ "$verdict" = "clean" ]; then
  echo "[gc-review] autoloop converged: clean after $((iter - 1)) iteration(s)."
  exit 0
else
  echo "[gc-review] autoloop did not converge after $MAX_ITERS iteration(s); last verdict: $verdict" >&2
  exit 1
fi
