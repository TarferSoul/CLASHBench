#!/bin/bash

stop_a() {
  . "$CASE_PRIVATE_ROOT/fixture.env"
  if [ ! -s "$A_STATE_ROOT/roster.json" ]; then
    echo "A_STOP_OK=1 reason=not_started"
    return 0
  fi
  local pid
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["supervisor"]["pid"])' "$A_STATE_ROOT/roster.json")
  touch "$A_STATE_ROOT/stop.request"
  chown "$SERVICE_UID:$SERVICE_GID" "$A_STATE_ROOT/stop.request"
  local deadline=$((SECONDS + A_STOP_TIMEOUT_SECONDS))
  while [ -e "/proc/$pid/stat" ] && [ "$SECONDS" -lt "$deadline" ]; do
    local state
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    [ "$state" = Z ] && break
    sleep 0.05
  done
  if [ -e "/proc/$pid/stat" ]; then
    local state
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ "$state" != Z ]; then
      kill -TERM "$pid" 2>/dev/null || true
      local term_deadline=$((SECONDS + 5))
      while [ -e "/proc/$pid/stat" ] && [ "$SECONDS" -lt "$term_deadline" ]; do
        state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
        [ "$state" = Z ] && break
        sleep 0.05
      done
    fi
  fi
  wait "$pid" 2>/dev/null || true
  if [ -e "/proc/$pid/stat" ]; then
    local final_state
    final_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ "$final_state" != Z ]; then
      echo "A_STOP_OK=0 pid=$pid state=$final_state" >&2
      return 1
    fi
  fi
  python3 - "$A_STATE_ROOT/health.json" <<'PY'
import json, pathlib, sys
health = json.loads(pathlib.Path(sys.argv[1]).read_text())
ok = health.get("state") == "stopped" and health.get("normal_stop") is True
print(f"A_STOP_OK={1 if ok else 0} state={health.get('state')} normal_stop={health.get('normal_stop')}")
raise SystemExit(0 if ok else 1)
PY
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "stop_a.sh must be sourced by the root lifecycle shell" >&2
  exit 2
fi
