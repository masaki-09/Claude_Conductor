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
#   model        = gemini-3-flash-preview  (implementer default; recon/review override to pro)
#   preamble     = prompts/worker-preamble.md
#                  (per-worker override: if <id>.preamble.md sits next to <id>.prompt
#                   it wins for that worker only — used by --aspects review)
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
MODEL="gemini-3-flash-preview"
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
  {
    cat "$effective_preamble"
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
  local gemini_args=(-p "" -o json --skip-trust --approval-mode "$MODE")
  if [ -n "$MODEL" ];        then gemini_args+=(-m "$MODEL"); fi
  if [ -n "$INCLUDE_DIRS" ]; then gemini_args+=(--include-directories "$INCLUDE_DIRS"); fi

  local pushd_dir="${WORKER_CWD:-$PWD}"

  echo "[gc-parallel] start  $id" >&2
  local rc=0
  local started_at; started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local start_ts; start_ts=$(date +%s)
  (
    cd "$pushd_dir" || exit 99
    gemini "${gemini_args[@]}" < "$combined"
  ) > "$log_file" 2>&1 || rc=$?
  local completed_at; completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local end_ts; end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))

  rm -f "$combined"
  echo "$rc" > "$exitcode_file"

  # Extract text and telemetry from JSON log
  local text_file="$TASK_DIR/$id.text"
  local usage_file="$TASK_DIR/$id.usage.json"
  python -c "
import json, sys, os
jid, task_dir, log_f, text_f, usage_f, start_iso, end_iso, dur, exit_c = sys.argv[1:]
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
        'started_at': start_iso, 'completed_at': end_iso,
        'duration_seconds': int(dur), 'exit_code': int(exit_c), 'status': 'unknown'
    }
    with open(usage_f, 'w', encoding='utf-8') as f:
        json.dump(usage, f, indent=2)
except Exception as e:
    with open(usage_f, 'w', encoding='utf-8') as f:
        json.dump({'id': jid, 'model': None, 'prompt_tokens': None, 'completion_tokens': None, 'total_tokens': None,
                   'started_at': start_iso, 'completed_at': end_iso, 'duration_seconds': int(dur), 'exit_code': int(exit_c), 'status': 'unknown'}, f, indent=2)
    if not os.path.exists(text_f):
        with open(text_f, 'w', encoding='utf-8') as f:
            f.write(f'ERROR: {str(e)}\\n')
" "$id" "$TASK_DIR" "$log_file" "$text_file" "$usage_file" "$started_at" "$completed_at" "$duration" "$rc" 2>/dev/null || true

  # Extract summary: prefer the marker block emitted by the preamble.
  # Implementers/recon use STATUS:; reviewer uses VERDICT:. Accept either.
  if grep -nE '^(STATUS|VERDICT):[[:space:]]' "$text_file" > /dev/null 2>&1; then
    awk '/^(STATUS|VERDICT):[[:space:]]/{p=1} p{print}' "$text_file" | tail -c 4096 > "$summary_file"
  else
    {
      echo "STATUS: unknown (no STATUS/VERDICT marker in worker output)"
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
  rm -f "$text_file"

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
    totals['total_tokens'] += w.get('total_tokens') or 0
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
