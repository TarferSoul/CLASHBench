#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

if [ ! -r "$A_STATE_FILE" ]; then
  echo "A_STOPPED=1 reason=no_state"
  exit 0
fi

pid=$(python3 - "$A_STATE_FILE" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("pid", ""))
except Exception:
    print("")
PY
)

if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
  echo "A_STOPPED=1 reason=not_running pid=${pid:-unknown}"
  exit 0
fi

pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi

for _ in $(seq 1 80); do
  if [ ! -d "/proc/$pid" ]; then
    echo "A_STOPPED=1 mode=graceful_sigterm pid=$pid pgid=${pgid:-unknown}"
    exit 0
  fi
  proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  stopped_phase=$(python3 - "$A_STOP_FILE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("0")
else:
    print("1" if data.get("phase") == "stopped" else "0")
PY
)
  if [ "$proc_state" = Z ] || [ "$stopped_phase" = 1 ]; then
    echo "A_STOPPED=1 mode=graceful_sigterm pid=$pid pgid=${pgid:-unknown} proc_state=${proc_state:-unknown} stopped_record=$stopped_phase"
    exit 0
  fi
  sleep 0.1
done

kill -KILL "$pid" 2>/dev/null || true
echo "A_STOPPED=0 mode=forced_after_timeout pid=$pid pgid=${pgid:-unknown}"
exit 1
