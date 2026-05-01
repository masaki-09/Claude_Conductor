#!/usr/bin/env bash
# lib/log-event.sh — Shared helper to append events to tasks/_session/events.jsonl.
# Sourced by gc-parallel.sh, gc-recon.sh, gc-review.sh, gc-dispatch.sh.
#
# Usage:
#   gc_log_event <event_name> [key=value ...]
#
# Each call appends one JSON object as a line. The helper auto-includes:
#   ts        — ISO 8601 UTC timestamp
#   event     — the event name passed as the first arg
#   script    — basename of the calling script (e.g. "gc-parallel")
#   pid       — calling process PID
#
# Additional key=value pairs become JSON fields. Values are auto-typed:
#   true|false|null → JSON literal; int / float → number; otherwise string.
#
# Concurrency: writes a single line via >> which is POSIX-atomic for messages
# under PIPE_BUF (~4096 bytes). Multiple parallel workers may safely append.
#
# Failure behavior: silent best-effort. If python or the filesystem isn't
# usable, the call is a no-op so it never breaks the calling script.

gc_log_event() {
  local event="$1"; shift || return 0
  local script
  script="$(basename "${BASH_SOURCE[1]:-${0:-unknown}}" .sh)"
  local ts pid file
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
  pid="$$"
  file="${REPO_ROOT:-$(pwd)}/tasks/_session/events.jsonl"

  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0

  GC_TS="$ts" GC_EVENT="$event" GC_SCRIPT="$script" GC_PID="$pid" \
    python -c '
import json, os, sys
obj = {
  "ts":     os.environ["GC_TS"],
  "event":  os.environ["GC_EVENT"],
  "script": os.environ["GC_SCRIPT"],
  "pid":    int(os.environ["GC_PID"]),
}
for kv in sys.argv[1:]:
    if "=" not in kv:
        continue
    k, _, v = kv.partition("=")
    if v in ("true", "false", "null"):
        obj[k] = {"true": True, "false": False, "null": None}[v]
    else:
        try:
            obj[k] = int(v)
        except ValueError:
            try:
                obj[k] = float(v)
            except ValueError:
                obj[k] = v
print(json.dumps(obj, ensure_ascii=False))
' "$@" >> "$file" 2>/dev/null || true
}
