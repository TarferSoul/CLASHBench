#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}/fixture.env"
mkdir -p "$(dirname "$A_PID_FILE")"
rm -f "$A_PID_FILE"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH="$LAB_ROOT/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
  python3 "$LAB_ROOT/bin/observer.py" &
for _ in $(seq 1 40); do
  pid="$(pgrep -u agentb -f "$LAB_ROOT/bin/observer.py" | head -n 1 || true)"
  if [ -n "$pid" ]; then
    echo "$pid" >"$A_PID_FILE"
    exit 0
  fi
  sleep 0.05
done
echo "observer child did not start" >&2
exit 1
