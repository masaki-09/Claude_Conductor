#!/usr/bin/env bash
# scripts/gc-resume.sh — Aggregates session events and produces a briefing.
#
# Usage:
#   scripts/gc-resume.sh [--quiet] [--since <duration>] [--out <path>] [--no-write]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QUIET=0
SINCE=""
OUT_FILE="$REPO_ROOT/tasks/_session/state.md"
WRITE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)    QUIET=1; shift ;;
    --since)    SINCE="$2"; shift 2 ;;
    --out)      OUT_FILE="$2"; shift 2 ;;
    --no-write) WRITE=0; shift ;;
    -h|--help)
      echo "Usage: scripts/gc-resume.sh [--quiet] [--since <duration>] [--out <path>] [--no-write]"
      echo ""
      echo "  --quiet         Suppress stdout; only write the file."
      echo "  --since <dur>   Only include events from the last <dur> (e.g. 2h, 48h, 7d)."
      echo "  --out <path>    Override output path. Default: tasks/_session/state.md"
      echo "  --no-write      Print to stdout but skip the file write."
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v python >/dev/null 2>&1; then
  echo "Error: python not found." >&2
  exit 2
fi

# Ensure output directory exists if writing
if [ "$WRITE" -eq 1 ]; then
  mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null || true
fi

# Bridge to Python
export GC_SINCE="$SINCE"
export GC_EVENTS_FILE="$REPO_ROOT/tasks/_session/events.jsonl"
export GC_PLAN_FILE="$REPO_ROOT/tasks/_session/plan.md"
export GC_REPO_ROOT="$REPO_ROOT"

BRIEFING=$(python - << 'PYEOF'
import os
import sys
import json
import datetime
import re
import subprocess
import io

# Force UTF-8 for stdout and stderr
if sys.version_info >= (3, 7):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

def parse_duration(dur_str):
    if not dur_str:
        return None
    match = re.match(r"(\d+)([hdm])", dur_str)
    if not match:
        return None
    val, unit = int(match.group(1)), match.group(2)
    now = datetime.datetime.utcnow()
    if unit == "h":
        return now - datetime.timedelta(hours=val)
    if unit == "d":
        return now - datetime.timedelta(days=val)
    if unit == "m":
        return now - datetime.timedelta(minutes=val)
    return None

iso_date = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
since_dt = parse_duration(os.environ.get("GC_SINCE"))
events_file = os.environ.get("GC_EVENTS_FILE")
plan_file = os.environ.get("GC_PLAN_FILE")
repo_root = os.environ.get("GC_REPO_ROOT")

# Active goal and Plan progress
active_goal = "(no plan.md found — describe what you're doing and write it)"
plan_progress = "(no plan written; consider drafting one for tasks expected to span 3+ batches)"
plan_content = ""

if os.path.exists(plan_file):
    try:
        with open(plan_file, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
            plan_content = "".join(lines)
            plan_progress = plan_content.strip()
            for line in lines:
                if "Goal:" in line:
                    active_goal = line.partition("Goal:")[2].strip()
                    break
    except Exception as e:
        sys.stderr.write(f"(error reading plan.md: {e})\n")

# Events
events = []
if os.path.exists(events_file):
    try:
        with open(events_file, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f, 1):
                if not line.strip(): continue
                try:
                    ev = json.loads(line)
                    ts_str = ev.get("ts")
                    if not ts_str: continue
                    ts = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
                    if since_dt and ts < since_dt:
                        continue
                    events.append(ev)
                except Exception:
                    sys.stderr.write(f"(skipped malformed line {i})\n")
    except Exception as e:
        sys.stderr.write(f"(error reading events.jsonl: {e})\n")

EMOJIS = {
    "batch_start": "🚀", "batch_end": "✅",
    "recon_start": "🔍", "recon_end": "✓",
    "review_start": "🧪", "review_end": "📋",
    "autofix_start": "🔧", "autofix_end": "🔧",
    "dispatch_start": "▶️", "dispatch_end": "▶",
}

def summarize_event(ev):
    name = ev.get("event", "unknown")
    emoji = EMOJIS.get(name, "•")
    ts_str = ev.get("ts", "           ")[11:16] # "HH:MM"
    summary = ""
    if name == "batch_start":
        summary = f"batch {ev.get('batch_id', '?')} started (workers={ev.get('workers', '?')}, model={ev.get('model', '?')})"
    elif name == "batch_end":
        summary = f"batch {ev.get('batch_id', '?')} ended (ok={ev.get('ok', 0)}, partial={ev.get('partial', 0)}, failed={ev.get('failed', 0)})"
    elif name == "recon_start":
        summary = f"recon started (out={ev.get('out', '?')})"
    elif name == "recon_end":
        summary = f"recon ended (exit={ev.get('exit', '?')})"
    elif name == "review_start":
        summary = f"review started (aspects={ev.get('aspects', '?')}, range={ev.get('range', '?')})"
    elif name == "review_end":
        summary = f"review ended (verdict={ev.get('verdict', '?')})"
    elif name == "autofix_start":
        summary = f"autofix iter {ev.get('iter', '?')} started"
    elif name == "autofix_end":
        summary = f"autofix iter {ev.get('iter', '?')} ended (exit={ev.get('exit', '?')})"
    elif name == "dispatch_start":
        summary = f"dispatch {ev.get('id', '?')} started"
    elif name == "dispatch_end":
        summary = f"dispatch {ev.get('id', '?')} ended (exit={ev.get('exit', '?')})"
    else:
        kv_pairs = [f"{k}={v}" for k, v in ev.items() if k not in ("ts", "event", "script", "pid")]
        summary = f"{name} ({', '.join(kv_pairs)})"
    return f"- {ts_str} {emoji} {summary}"

recent_events = events[-30:]
activity_lines = [summarize_event(ev) for ev in recent_events]
if not activity_lines:
    activity_lines = ["(no events recorded yet)"]

# Git info
is_git = True
try:
    commits = subprocess.check_output(["git", "-C", repo_root, "log", "--oneline", "-20"], stderr=subprocess.STDOUT).decode("utf-8", errors="replace").strip()
    status = subprocess.check_output(["git", "-C", repo_root, "status", "--short"], stderr=subprocess.STDOUT).decode("utf-8", errors="replace").strip()
    if not status: status = "(clean)"
except Exception:
    is_git = False
    commits = "(not a git repo)"
    status = "(n/a)"

# Next step heuristic
def get_next_step():
    last_event = events[-1] if events else None
    if last_event and last_event.get("event") == "batch_end" and last_event.get("failed", 0) > 0:
        return f"Investigate failed worker(s) in {last_event.get('batch_id', '?')}"
    if "[ ]" in plan_content:
        return "Continue with first unchecked plan item"
    if is_git and status != "(clean)":
        return "Commit current working tree changes"
    for ev in reversed(events):
        if ev.get("event") == "review_end":
            if ev.get("verdict") in ("issues", "blocking"):
                return "Run autofix or address findings"
            break
    return "Plan next batch or summarize results to user"

next_step = get_next_step()

# Assemble briefing
output = []
output.append(f"# Session state — {iso_date}")
output.append(f"\n## Active goal")
output.append(active_goal)
output.append(f"\n## Plan progress")
output.append(plan_progress)
output.append(f"\n## Recent activity")
output.extend(activity_lines)
output.append(f"\n## Recent commits (last 20)")
output.append(commits)
output.append(f"\n## Working tree")
output.append(status)
output.append(f"\n## Suggested next step")
output.append(next_step)

sys.stdout.write("\n".join(output) + "\n")
PYEOF
)


# Output
if [ "$WRITE" -eq 1 ]; then
  printf '%s\n' "$BRIEFING" > "$OUT_FILE"
fi

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "$BRIEFING"
fi
