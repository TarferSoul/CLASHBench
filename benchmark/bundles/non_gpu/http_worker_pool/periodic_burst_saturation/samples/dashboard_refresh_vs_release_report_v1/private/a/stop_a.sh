#!/usr/bin/env bash
set -u
part=$1
stop_pid_file() {
  local file=$1 pid
  [ -s "$file" ] || return 0
  pid=$(python3 - "$file" <<'PY'
import json, sys
try:
 print(json.load(open(sys.argv[1])).get("pid", 0))
except Exception:
 print(0)
PY
)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
}
case "$part" in
  scheduler) stop_pid_file "$SCHEDULER_PID_FILE" ;;
  service) stop_pid_file "$SERVICE_PID_FILE" ;;
  all) stop_pid_file "$SCHEDULER_PID_FILE"; stop_pid_file "$SERVICE_PID_FILE" ;;
  *) exit 2 ;;
esac
printf 'A_STOPPED=1 component=%s\n' "$part"
