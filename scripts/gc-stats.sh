#!/usr/bin/env bash
# gc-stats.sh — Aggregate and report Gemini token usage.
#
# Usage:
#   scripts/gc-stats.sh [--since <duration>] [--since-batch <id>] [--by <dimension>] [--json]
#
# Options:
#   --since <duration>    Only count batches from last Nh, Nd, or Nm (e.g. 24h, 7d). Default: 24h.
#   --since-batch <id>    Only count batches whose ID sorts >= <id>.
#   --by <dimension>      Group by: model|status|batch|day|worker_type. Default: model.
#   --json                Output raw JSON instead of a table.
#   -h, --help            Show this help.

set -uo pipefail

# Approximate public pricing per 1M tokens (USD), as of 2026-05.
PRICE_FLASH_INPUT="0.30"
PRICE_FLASH_OUTPUT="2.50"
PRICE_PRO_INPUT="3.00"
PRICE_PRO_OUTPUT="15.00"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_DIR="$REPO_ROOT/tasks"

SINCE="24h"
SINCE_BATCH=""
BY="model"
OUTPUT_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --since)       SINCE="$2"; shift 2 ;;
    --since-batch) SINCE_BATCH="$2"; shift 2 ;;
    --by)          BY="$2"; shift 2 ;;
    --json)        OUTPUT_JSON=1; shift ;;
    -h|--help)
      sed -n '2,13p' "$0"; exit 0 ;;
    -*)
      echo "[gc-stats] unknown flag: $1" >&2; exit 2 ;;
    *)
      echo "[gc-stats] unexpected positional arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$TASKS_DIR" ] || [ -z "$(ls -A "$TASKS_DIR" 2>/dev/null)" ]; then
  echo "No batches found in tasks/."
  exit 0
fi

if ! command -v python >/dev/null 2>&1; then
  echo "[gc-stats] error: gc-stats requires python (v3 recommended)" >&2
  exit 1
fi

# Pass everything to Python for processing.
python - "$TASKS_DIR" "$SINCE" "$SINCE_BATCH" "$BY" "$OUTPUT_JSON" <<EOF
import os
import sys
import json
import datetime
import glob
import re

tasks_dir = sys.argv[1]
since_str = sys.argv[2]
since_batch = sys.argv[3]
group_by = sys.argv[4]
output_json = sys.argv[5] == "1"

# Pricing
PRICES = {
    "gemini-3-flash-preview": {"in": float("$PRICE_FLASH_INPUT"), "out": float("$PRICE_FLASH_OUTPUT")},
    "gemini-3-pro-preview": {"in": float("$PRICE_PRO_INPUT"), "out": float("$PRICE_PRO_OUTPUT")},
}

def parse_duration(d_str):
    match = re.match(r'^(\d+)([hdm])$', d_str)
    if not match:
        return datetime.timedelta(hours=24)
    val = int(match.group(1))
    unit = match.group(2)
    if unit == 'h': return datetime.timedelta(hours=val)
    if unit == 'd': return datetime.timedelta(days=val)
    if unit == 'm': return datetime.timedelta(minutes=val)
    return datetime.timedelta(hours=24)

now = datetime.datetime.now(datetime.timezone.utc)
since_delta = parse_duration(since_str)
since_time = now - since_delta

def get_worker_type(batch_id):
    if batch_id.startswith("recon-"): return "recon"
    if batch_id.startswith("review-"): return "review"
    if batch_id.startswith("autofix-"): return "autofix"
    if batch_id.startswith("oneshot-"): return "oneshot"
    return "impl"

batches = []
total_workers = 0
ok_workers = 0
partial_workers = 0
failed_workers = 0
telemetry_missing = 0

aggregated = {} # key -> {workers, prompt, completion, total, cost}

for batch_dir_name in sorted(os.listdir(tasks_dir)):
    if since_batch and batch_dir_name < since_batch:
        continue
    
    batch_path = os.path.join(tasks_dir, batch_dir_name)
    if not os.path.isdir(batch_path):
        continue
    
    batch_usage_path = os.path.join(batch_path, "_batch.usage.json")
    if not os.path.exists(batch_usage_path):
        continue
    
    try:
        with open(batch_usage_path, 'r') as f:
            batch_data = json.load(f)
    except Exception as e:
        sys.stderr.write(f"Warning: Failed to parse {batch_usage_path}: {e}\n")
        continue

    # Filter by started_at if --since-batch is NOT set
    if not since_batch:
        started_at_str = batch_data.get("started_at")
        if not started_at_str:
            continue
        try:
            # Handle Z or +00:00
            dt_str = started_at_str.replace('Z', '+00:00')
            started_at = datetime.datetime.fromisoformat(dt_str)
            if started_at < since_time:
                continue
        except:
            continue

    batches.append(batch_data)
    
    # Process individual workers for this batch
    for worker_usage_path in glob.glob(os.path.join(batch_path, "*.usage.json")):
        if os.path.basename(worker_usage_path) == "_batch.usage.json":
            continue
            
        try:
            with open(worker_usage_path, 'r') as f:
                worker_data = json.load(f)
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to parse {worker_usage_path}: {e}\n")
            telemetry_missing += 1
            continue
            
        total_workers += 1
        status = worker_data.get("status", "unknown")
        if status == "ok": ok_workers += 1
        elif status == "partial": partial_workers += 1
        elif status == "failed": failed_workers += 1
        
        prompt = worker_data.get("prompt_tokens") or 0
        completion = worker_data.get("completion_tokens") or 0
        total = worker_data.get("total_tokens") or 0
        model = worker_data.get("model", "unknown")
        
        if worker_data.get("prompt_tokens") is None or worker_data.get("completion_tokens") is None:
            telemetry_missing += 1
            
        # Grouping key
        if group_by == "model": key = model
        elif group_by == "status": key = status
        elif group_by == "batch": key = batch_dir_name
        elif group_by == "day": 
            started = worker_data.get("started_at", "")
            key = started[:10] if started else "unknown"
        elif group_by == "worker_type": key = get_worker_type(batch_dir_name)
        else: key = model
        
        if key not in aggregated:
            aggregated[key] = {"workers": 0, "prompt": 0, "completion": 0, "total": 0, "cost": 0.0, "cost_unknown": False}
        
        aggregated[key]["workers"] += 1
        aggregated[key]["prompt"] += prompt
        aggregated[key]["completion"] += completion
        aggregated[key]["total"] += total
        
        if model in PRICES:
            cost = (prompt / 1e6) * PRICES[model]["in"] + (completion / 1e6) * PRICES[model]["out"]
            aggregated[key]["cost"] += cost
        else:
            aggregated[key]["cost_unknown"] = True

if not batches:
    if since_batch:
        print(f"No batches found starting from {since_batch}.")
    else:
        print(f"No telemetry data in last {since_str}.")
    sys.exit(0)

if output_json:
    report = {
        "period": {
            "since": since_str,
            "since_batch": since_batch,
            "batches_count": len(batches)
        },
        "workers": {
            "total": total_workers,
            "ok": ok_workers,
            "partial": partial_workers,
            "failed": failed_workers,
            "telemetry_coverage": f"{total_workers - telemetry_missing}/{total_workers}"
        },
        "breakdown_by": group_by,
        "results": aggregated
    }
    print(json.dumps(report, indent=2))
else:
    # Human readable output
    # Find period range
    start_dates = [b["started_at"][:10] for b in batches if b.get("started_at")]
    period = f"{min(start_dates)}..{max(start_dates)}" if start_dates else "unknown"
    
    batch_types = {}
    for b in batches:
        t = get_worker_type(b.get("batch_id", "impl"))
        batch_types[t] = batch_types.get(t, 0) + 1
    type_str = ", ".join([f"{v} {k}" for k, v in batch_types.items()])
    
    print(f"Period: {period} (last {since_str})" if not since_batch else f"Period: {period} (since batch {since_batch})")
    print(f"Batches: {len(batches)} ({type_str})")
    print(f"Workers: {ok_workers} ok, {partial_workers} partial, {failed_workers} failed")
    coverage_pct = (100 * (total_workers - telemetry_missing) // total_workers) if total_workers > 0 else 0
    print(f"Telemetry coverage: {total_workers - telemetry_missing}/{total_workers} workers ({coverage_pct}%)")
    print("")
    print(f"By {group_by}:")
    
    total_cost = 0.0
    any_unknown_cost = False
    
    for key in sorted(aggregated.keys()):
        data = aggregated[key]
        print(f"  {key:<26} {data['workers']:>2} workers  {data['prompt']:>8,} prompt  {data['completion']:>7,} out  {data['total']:>8,} total")
        total_cost += data["cost"]
        if data["cost_unknown"]: any_unknown_cost = True

    print("")
    print("Estimated cost (rough, public list pricing):")
    for key in sorted(aggregated.keys()):
        data = aggregated[key]
        cost_val = f"\${data['cost']:.3f}" if not data["cost_unknown"] else "unknown"
        print(f"  {key:<26} {cost_val}")
    
    print("  " + "-" * 5)
    total_cost_str = f"\${total_cost:.3f}" + ("?" if any_unknown_cost else "")
    print(f"  total                      {total_cost_str}")
    
    if telemetry_missing > 0:
        print(f"\n({telemetry_missing} workers had no usage data — actual cost may be higher)")

EOF
