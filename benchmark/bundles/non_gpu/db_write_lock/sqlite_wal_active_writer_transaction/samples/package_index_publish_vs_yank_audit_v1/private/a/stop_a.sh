#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
[ -s "$A_STATUS_FILE" ] || { echo 'A_STOPPED=1 reason=no_status'; exit 0; }
pid=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["pid"]))' "$A_STATUS_FILE")
if [ -d "/proc/$pid" ]; then
  kill -USR1 "$pid" 2>/dev/null || true
fi
committed=0
for _ in $(seq 1 140); do
  if [ -s "$A_STATUS_FILE" ] && python3 - "$A_STATUS_FILE" <<'PY' >/dev/null 2>&1
import json, sys
assert json.load(open(sys.argv[1]))["phase"] == "committed"
PY
  then committed=1; break; fi
  sleep 0.05
done
if [ "$committed" != 1 ]; then
  kill -TERM "$pid" 2>/dev/null || true
  echo "A_STOPPED=0 pid=$pid reason=graceful_publish_timeout" >&2
  exit 1
fi
echo "A_STOPPED=1 pid=$pid mode=graceful_publish"
