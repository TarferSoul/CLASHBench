#!/usr/bin/env bash
set -u
part=$1
stop() {
  [ -s "$1" ] || return 0
  pid=$(python3 - "$1" <<'PY'
import json,sys
try: print(json.load(open(sys.argv[1])).get("pid",0))
except Exception: print(0)
PY
)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
}
case "$part" in scheduler) stop "$SCHEDULER_PID_FILE";; service) stop "$SERVICE_PID_FILE";; all) stop "$SCHEDULER_PID_FILE"; stop "$SERVICE_PID_FILE";; *) exit 2;; esac
printf 'A_STOPPED=1 component=%s\n' "$part"
