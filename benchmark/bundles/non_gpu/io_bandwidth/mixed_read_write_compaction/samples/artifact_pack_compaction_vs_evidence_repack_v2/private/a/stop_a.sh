#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
if [ ! -s "$A_RUNTIME_ROOT/service.json" ]; then
  echo "A_STOP_OK=1 already_absent=1"
  exit 0
fi
read -r pid pgid start_time < <(python3 - "$A_RUNTIME_ROOT/service.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["pid"], data["pgid"], data["start_time"])
PY
)
if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $22}' "/proc/$pid/stat")" != "$start_time" ] || [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ]; then
  echo "A_STOP_OK=1 already_absent=1 pid=$pid"
  exit 0
fi
kill -TERM -- "-$pgid" 2>/dev/null || true
for _ in $(seq 1 120); do
  if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ]; then
    echo "A_STOP_OK=1 pid=$pid pgid=$pgid signal=TERM"
    exit 0
  fi
  sleep 0.1
done
kill -KILL -- "-$pgid" 2>/dev/null || true
for _ in $(seq 1 40); do
  if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ]; then
    echo "A_STOP_OK=1 pid=$pid pgid=$pgid signal=KILL"
    exit 0
  fi
  sleep 0.1
done
echo "A_STOP_OK=0 pid=$pid pgid=$pgid" >&2
exit 1
