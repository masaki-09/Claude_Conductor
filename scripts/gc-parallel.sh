#!/usr/bin/env bash
# gc-parallel.sh — Dispatch a batch of Gemini CLI workers in parallel.
#
# Usage:
#   scripts/gc-parallel.sh <task-dir> [--max-parallel N] [--model NAME]
#                                     [--cwd PATH] [--include DIR[,DIR]]
#                                     [--preamble PATH] [--context-file PATH]
#                                     [--mode yolo|auto_edit|plan|default]
#                                     [--retries N] [--retry-on PATTERN]
#                                     [--fallback-model NAME] [--dry-run]
#
# <task-dir> must contain one or more *.prompt files. Each *.prompt becomes
# one worker. The basename (without .prompt) is the worker ID.
#
# For each worker <id>, this script writes:
#   <task-dir>/<id>.log        — full worker stdout+stderr (large; do NOT read by default)
#   <task-dir>/<id>.summary    — short tail used by the conductor
#   <task-dir>/<id>.exitcode   — process exit code as text
#   <task-dir>/<id>.status     — ok | partial | failed | ok-fallback |
#                                  partial-fallback | unknown
#   <task-dir>/<id>.text       — extracted plain-text response (humans)
#   <task-dir>/<id>.usage.json — per-worker token usage (prompt/completion
#                                  /total/derived_total) and timing
#   <task-dir>/_batch.usage.json — batch-level aggregated token usage
#
# Each worker's input is built as: <preamble> + <context-file?> + <task body>.
# This lets recon output be prepended automatically (see scripts/gc-recon.sh).
#
# Defaults:
#   max-parallel = 4
#   model        = gemini-3-flash-preview  (implementer default; recon/review override to pro)
#   preamble     = prompts/worker-preamble.md
#                  (per-worker override: if <id>.preamble.md sits next to <id>.prompt
#                   it wins for that worker only — used by --aspects review)
#   context-file = (none)
#   mode         = yolo            (use 'plan' for read-only recon/review workers)
#   retries      = 0               (per-worker retries on transient errors)
#   retry-on     = (none)          (extra regex pattern to trigger retry)
#   fallback-model = (none)        (one last attempt with this model if primary fails)

set -uo pipefail

# ---------- locate repo root ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/log-event.sh
. "$REPO_ROOT/lib/log-event.sh" 2>/dev/null || true
DEFAULT_PREAMBLE="$REPO_ROOT/prompts/worker-preamble.md"

# ---------- parse args ----------
TASK_DIR=""
MAX_PARALLEL=4
MODEL="gemini-3-flash-preview"
WORKER_CWD=""
INCLUDE_DIRS=""
PREAMBLE_FILE=""
CONTEXT_FILE=""
MODE="yolo"
RETRIES=0
RETRY_ON=""
FALLBACK_MODEL=""
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
    --retries)      RETRIES="$2"; shift 2 ;;
    --retry-on)     RETRY_ON="${RETRY_ON:+$RETRY_ON|}$2"; shift 2 ;;
    --fallback-model) FALLBACK_MODEL="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,36p' "$0"; exit 0 ;;
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
gc_log_event batch_start \
  batch_id="$(basename "$TASK_DIR")" \
  task_dir="$TASK_DIR" \
  workers="${#PROMPT_FILES[@]}" \
  max_parallel="$MAX_PARALLEL" \
  model="$MODEL" \
  mode="$MODE" \
  retries="$RETRIES" \
  fallback_model="${FALLBACK_MODEL:-none}"
echo "[gc-parallel] workers: ${#PROMPT_FILES[@]}, max-parallel: $MAX_PARALLEL, mode: $MODE${MODEL:+, model: $MODEL}${WORKER_CWD:+, cwd: $WORKER_CWD}${CONTEXT_FILE:+, context: $CONTEXT_FILE}"

if [ "$DRY_RUN" -eq 1 ]; then
  for f in "${PROMPT_FILES[@]}"; do echo "  would dispatch: $(basename "$f")"; done
  exit 0
fi

# ---------- concurrent run protection ----------
LOCKFILE="$TASK_DIR/.gc-parallel.lock"
if [ -f "$LOCKFILE" ]; then
  existing_pid="$(cat "$LOCKFILE" 2>/dev/null)"
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "[gc-parallel] another gc-parallel run is already active in this task dir (pid $existing_pid)" >&2
    echo "[gc-parallel] if you're sure no other run is active, remove $LOCKFILE manually" >&2
    exit 3
  else
    echo "[gc-parallel] stale lockfile (pid $existing_pid not running) — removing" >&2
    rm -f "$LOCKFILE"
  fi
fi
echo "$$" > "$LOCKFILE"

# Ensure cleanup on any exit. Note: run_worker uses its own traps for local
# tempfiles; this global trap ensures the lockfile is removed.
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# ---------- worker function ----------
run_worker() {
  local prompt_file="$1"
  local id; id="$(basename "$prompt_file" .prompt)"
  local log_file="$TASK_DIR/$id.log"
  local summary_file="$TASK_DIR/$id.summary"
  local exitcode_file="$TASK_DIR/$id.exitcode"
  local status_file="$TASK_DIR/$id.status"

  # Per-worker preamble override: if a sibling <id>.preamble.md exists, use it
  # instead of the global preamble. Used by gc-review.sh --aspects to give each
  # aspect-reviewer its own contract within a single batch.
  local effective_preamble="$PREAMBLE_FILE"
  local per_prompt_preamble="${prompt_file%.prompt}.preamble.md"
  if [ -f "$per_prompt_preamble" ]; then
    effective_preamble="$per_prompt_preamble"
  fi

  # Build full prompt: preamble + (optional) context + task body
  local combined; combined="$(mktemp)"
  trap 'rm -f "$combined"' RETURN INT TERM EXIT
  {
    cat "$effective_preamble"
    echo
    if [ -n "$CONTEXT_FILE" ]; then
      echo "## Prepended context"
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
  local gemini_args=(-p "" -o json --skip-trust --approval-mode "$MODE")
  if [ -n "$MODEL" ];        then gemini_args+=(-m "$MODEL"); fi
  if [ -n "$INCLUDE_DIRS" ]; then gemini_args+=(--include-directories "$INCLUDE_DIRS"); fi

  local pushd_dir="${WORKER_CWD:-$PWD}"
  local TRANSIENT_RX='429|RESOURCE_EXHAUSTED|QUOTA_EXHAUSTED|UNAVAILABLE|INTERNAL|DEADLINE_EXCEEDED|gaxios-gaxios-error.*5\d\d'
  local HARD_LIMIT_RX='TerminalQuotaError|Your quota will reset after|retryDelayMs:|retry":\s*false'

  echo "[gc-parallel] start  $id" >&2
  local rc=0
  local attempt=0
  local max_attempts=$((1 + RETRIES))
  local used_fallback=0
  local final_model="$MODEL"
  local started_at; started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local start_ts; start_ts=$(date +%s)

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    (
      cd "$pushd_dir" || exit 99
      gemini "${gemini_args[@]}" < "$combined"
    ) > "$log_file" 2>&1 || rc=$?

    if [ $rc -eq 0 ]; then break; fi

    # Check for transient errors to trigger retry
    if grep -qE "$TRANSIENT_RX|${RETRY_ON:-(?!.*)}" "$log_file"; then
      if [ $attempt -lt $max_attempts ]; then
        local delay=$((2 * 3 ** (attempt - 1)))
        echo "[gc-parallel] retry  $id (attempt $attempt/$max_attempts, transient error, sleeping ${delay}s)" >&2
        sleep $delay
        continue
      fi
    fi
    break
  done

  # Fallback model attempt
  if [ $rc -ne 0 ] && [ -n "$FALLBACK_MODEL" ] && [ "$FALLBACK_MODEL" != "$MODEL" ]; then
    used_fallback=1
    final_model="$FALLBACK_MODEL"
    echo "[gc-parallel] fallback $id (primary failed, trying $FALLBACK_MODEL)" >&2
    local fallback_args=()
    for arg in "${gemini_args[@]}"; do
      if [ "$arg" = "$MODEL" ]; then fallback_args+=("$FALLBACK_MODEL"); else fallback_args+=("$arg"); fi
    done
    # If -m wasn't in gemini_args (unlikely if MODEL was set), we should ensure it is
    if [[ ! " ${fallback_args[*]} " =~ " -m " ]]; then
        fallback_args+=(-m "$FALLBACK_MODEL")
    fi

    (
      cd "$pushd_dir" || exit 99
      gemini "${fallback_args[@]}" < "$combined"
    ) > "$log_file" 2>&1 || rc=$?
  fi

  local completed_at; completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local end_ts; end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))

  rm -f "$combined"
  echo "$rc" > "$exitcode_file"

  # Detect hard rate limits that warrant a pause instead of simple failure
  local is_hard_limit=0
  if [ $rc -ne 0 ] && grep -qE "$HARD_LIMIT_RX" "$log_file"; then
    if grep -qE "TerminalQuotaError|Your quota will reset after" "$log_file"; then
      is_hard_limit=1
    elif grep -q "retryDelayMs" "$log_file"; then
      local delay_ms; delay_ms=$(grep -oE "retryDelayMs:[[:space:]]*[0-9]+" "$log_file" | awk -F: '{print $2}' | tr -d '[:space:]')
      if [ -n "$delay_ms" ] && [ "$delay_ms" -gt 600000 ]; then
        is_hard_limit=1
      fi
    elif grep -q "QUOTA_EXHAUSTED" "$log_file" && grep -qE '"retry":[[:space:]]*false' "$log_file"; then
      is_hard_limit=1
    fi
  fi

  # Extract text and telemetry from JSON log
  local text_file="$TASK_DIR/$id.text"
  local usage_file="$TASK_DIR/$id.usage.json"
  python -c "
import json, sys, os
jid, task_dir, log_f, text_f, usage_f, start_iso, end_iso, dur, exit_c, attempts, used_fb = sys.argv[1:]
try:
    with open(log_f, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    start_idx = content.find('{')
    end_idx = content.rfind('}')
    if start_idx == -1 or end_idx == -1 or end_idx < start_idx:
        raise ValueError('No JSON found')
    data = json.loads(content[start_idx:end_idx+1])
    with open(text_f, 'w', encoding='utf-8') as f:
        f.write(data.get('response', ''))
    stats = data.get('stats', {})
    models = stats.get('models', {})
    m_name, p_tok, c_tok, t_tok = None, 0, 0, 0
    for m, m_stats in models.items():
        toks = m_stats.get('tokens', {})
        p, c, t = toks.get('input', 0), toks.get('candidates', 0), toks.get('total', 0)
        if t > 0:
            if not m_name: m_name = m
            p_tok += p; c_tok += c; t_tok += t
    if not m_name and models: m_name = list(models.keys())[0]
    usage = {
        'id': jid, 'model': m_name,
        'prompt_tokens': p_tok if t_tok > 0 else None,
        'completion_tokens': c_tok if t_tok > 0 else None,
        'total_tokens': t_tok if t_tok > 0 else None,
        'derived_total_tokens': (p_tok + c_tok) if t_tok > 0 else None,
        'started_at': start_iso, 'completed_at': end_iso,
        'duration_seconds': int(dur), 'exit_code': int(exit_c), 'status': 'unknown',
        'attempts': int(attempts), 'used_fallback': used_fb == '1'
    }
    with open(usage_f, 'w', encoding='utf-8') as f:
        json.dump(usage, f, indent=2)
except Exception as e:
    with open(usage_f, 'w', encoding='utf-8') as f:
        json.dump({'id': jid, 'model': None, 'prompt_tokens': None, 'completion_tokens': None, 'total_tokens': None, 'derived_total_tokens': None,
                   'started_at': start_iso, 'completed_at': end_iso, 'duration_seconds': int(dur), 'exit_code': int(exit_c), 'status': 'unknown',
                   'attempts': int(attempts), 'used_fallback': used_fb == '1'}, f, indent=2)
    if not os.path.exists(text_f):
        with open(text_f, 'w', encoding='utf-8') as f:
            f.write(f'ERROR: {str(e)}\\n')
" "$id" "$TASK_DIR" "$log_file" "$text_file" "$usage_file" "$started_at" "$completed_at" "$duration" "$rc" "$attempt" "$used_fallback" 2>/dev/null || true

  # Extract summary: prefer the marker block emitted by the preamble.
  # Implementers/recon use STATUS:; reviewer uses VERDICT:. Accept either.
  if grep -nE '^(STATUS|VERDICT):[[:space:]]' "$text_file" > /dev/null 2>&1; then
    awk '/^(STATUS|VERDICT):[[:space:]]/{p=1} p{print}' "$text_file" | tail -c 4096 > "$summary_file"
  else
    {
      if [ "$rc" -eq 0 ]; then
        echo "STATUS: unknown (no STATUS/VERDICT marker in worker output)"
      else
        echo "STATUS: failed (exit=$rc)"
      fi
      echo "--- output tail ---"
      tail -n 30 "$text_file" 2>/dev/null || tail -n 30 "$log_file"
    } > "$summary_file"
  fi

  local final_status="unknown"
  if [ "$rc" -eq 0 ]; then
    # Map both schemas onto a single status vocabulary: ok / partial / failed.
    if   grep -qE '^STATUS:[[:space:]]*ok'        "$summary_file"; then final_status="ok"
    elif grep -qE '^VERDICT:[[:space:]]*clean'    "$summary_file"; then final_status="ok"
    elif grep -qE '^STATUS:[[:space:]]*partial'   "$summary_file"; then final_status="partial"
    elif grep -qE '^VERDICT:[[:space:]]*issues'   "$summary_file"; then final_status="partial"
    elif grep -qE '^STATUS:[[:space:]]*failed'    "$summary_file"; then final_status="failed"
    elif grep -qE '^VERDICT:[[:space:]]*blocking' "$summary_file"; then final_status="failed"
    fi
    if [ "$used_fallback" -eq 1 ] && [[ "$final_status" =~ ^(ok|partial)$ ]]; then
      final_status="${final_status}-fallback"
    fi
  elif [ "$is_hard_limit" -eq 1 ]; then
    final_status="paused-quota"
    python -c "
import json, sys, os, re, datetime
jid, t_dir, log_f, p_f, pre_f, ctx_f, model, mode, cwd, incs, paused, atts = sys.argv[1:]
with open(log_f, 'r', encoding='utf-8', errors='ignore') as f: log = f.read()
ra = None
m1 = re.search(r'Your quota will reset after (\d+)h(\d+)m(\d+)s', log)
if m1: h, m, s = map(int, m1.groups()); ra = h*3600 + m*60 + s
else:
    m2 = re.search(r'retryDelayMs:\s*(\d+)', log)
    if m2: ra = int(m2.group(1)) // 1000
er = None
if ra:
    try:
        dt = datetime.datetime.fromisoformat(paused.replace('Z', '+00:00'))
        er = (dt + datetime.timedelta(seconds=ra)).isoformat().replace('+00:00', 'Z')
    except: pass
exc = ''
sigs = ['TerminalQuotaError', 'Your quota will reset after', 'retryDelayMs', '\"retry\": false']
ls = log.splitlines()
for i, l in enumerate(ls):
    if any(s in l for s in sigs): exc = ' '.join(ls[i:i+4])[:200]; break
pd = {
    'id': jid, 'batch_id': os.environ.get('GC_BATCH_ID_OVERRIDE') or os.path.basename(t_dir.rstrip('/\\\\')), 'task_dir': os.path.abspath(t_dir),
    'prompt_file': os.path.abspath(p_f), 'preamble_file': os.path.abspath(pre_f),

    'context_file': os.path.abspath(ctx_f) if (ctx_f and os.path.exists(ctx_f)) else None,
    'model': model, 'mode': mode, 'cwd': os.path.abspath(cwd) if cwd else None,
    'include_dirs': incs if incs else None, 'paused_at': paused, 'reset_after_seconds': ra,
    'estimated_resume_at': er, 'attempts': int(atts), 'last_error_excerpt': exc
}
with open(os.path.join(t_dir, jid + '.pause.json'), 'w', encoding='utf-8') as f: json.dump(pd, f, indent=2)
print(er or 'unknown')
" "$id" "$TASK_DIR" "$log_file" "$prompt_file" "$effective_preamble" "$CONTEXT_FILE" "$final_model" "$MODE" "$WORKER_CWD" "$INCLUDE_DIRS" "$completed_at" "$attempt" > "$TASK_DIR/$id.resume_at" 2>/dev/null || true

    estimated_resume_at=$(cat "$TASK_DIR/$id.resume_at" 2>/dev/null || echo "unknown")
    rm -f "$TASK_DIR/$id.resume_at"

    {
      echo "STATUS: paused-quota"
      echo "FILES: (none — worker did not produce output)"
      echo "NOTES: Hit hard rate limit. Resume after $estimated_resume_at using scripts/gc-resume-workers.sh tasks/$(basename "$TASK_DIR")."
    } > "$summary_file"

    gc_log_event worker_paused \
      batch_id="$(basename "$TASK_DIR")" \
      worker_id="$id" \
      model="$final_model" \
      estimated_resume_at="$estimated_resume_at"
  else
    final_status="failed (exit=$rc)"
  fi
  echo "$final_status" > "$status_file"


  # Finalize usage file with the determined status
  python -c "
import json, sys
f_path, status = sys.argv[1:]
try:
    with open(f_path, 'r', encoding='utf-8') as f: data = json.load(f)
    data['status'] = status
    with open(f_path, 'w', encoding='utf-8') as f: json.dump(data, f, indent=2)
except: pass
" "$usage_file" "$final_status" 2>/dev/null || true

  echo "[gc-parallel] done   $id (exit=$rc, status=$final_status)" >&2
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
# Aggregate telemetry
python -c "
import json, os, glob, sys
task_dir = sys.argv[1]
batch_id = os.path.basename(task_dir.rstrip('/\\\\'))
usage_files = glob.glob(os.path.join(task_dir, '*.usage.json'))
usage_files = [f for f in usage_files if not os.path.basename(f).startswith('_')]
workers = []
for f in usage_files:
    try:
        with open(f, 'r', encoding='utf-8') as jf: workers.append(json.load(jf))
    except: pass
by_model, by_status = {}, {}
totals = {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0}
starts, ends = [], []
for w in workers:
    m = w.get('model'); s = w.get('status')
    if m: by_model[m] = by_model.get(m, 0) + 1
    if s: by_status[s] = by_status.get(s, 0) + 1
    totals['prompt_tokens'] += w.get('prompt_tokens') or 0
    totals['completion_tokens'] += w.get('completion_tokens') or 0
    # Use derived_total_tokens for the batch total to ensure total == prompt + completion
    totals['total_tokens'] += w.get('derived_total_tokens') or 0
    if w.get('started_at'): starts.append(w['started_at'])
    if w.get('completed_at'): ends.append(w['completed_at'])
aggregate = {
    'batch_id': batch_id, 'worker_count': len(workers),
    'by_model': by_model, 'by_status': by_status, 'totals': totals,
    'started_at': min(starts) if starts else None, 'completed_at': max(ends) if ends else None
}
with open(os.path.join(task_dir, '_batch.usage.json'), 'w', encoding='utf-8') as f:
    json.dump(aggregate, f, indent=2)
" "$TASK_DIR" 2>/dev/null || true

echo
echo "[gc-parallel] batch complete: $TASK_DIR"
ok_count=0
partial_count=0
fail_count=0
pause_count=0
for f in "${PROMPT_FILES[@]}"; do
  id="$(basename "$f" .prompt)"
  status="$(cat "$TASK_DIR/$id.status" 2>/dev/null || echo unknown)"
  printf "  %-30s %s\n" "$id" "$status"
  case "$status" in
    ok|ok-fallback) ok_count=$((ok_count + 1)) ;;
    partial|partial-fallback)
      partial_count=$((partial_count + 1))
      fail_count=$((fail_count + 1))
      ;;
    paused-quota)
      pause_count=$((pause_count + 1))
      ;;
    *) fail_count=$((fail_count + 1)) ;;
  esac
done

gc_log_event batch_end \
  batch_id="$(basename "$TASK_DIR")" \
  exit="$fail_count" \
  ok="$ok_count" \
  partial="$partial_count" \
  failed="$fail_count" \
  paused="$pause_count"

if [ "$fail_count" -gt 0 ]; then
  echo "[gc-parallel] $fail_count worker(s) not ok — inspect the corresponding *.summary and only fall back to *.log if needed." >&2
  exit 1
fi
if [ "$pause_count" -gt 0 ]; then
  echo "[gc-parallel] $pause_count worker(s) paused due to rate limits. Resume with scripts/gc-resume-workers.sh." >&2
  exit 4
fi
exit 0
