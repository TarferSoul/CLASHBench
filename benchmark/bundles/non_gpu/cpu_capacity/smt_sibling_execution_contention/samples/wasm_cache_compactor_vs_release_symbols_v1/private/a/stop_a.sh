#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
[ -s "$A_PID_FILE" ] || { echo "A_STOP_OK=1 already_stopped=1"; exit 0; }
pid=$(<"$A_PID_FILE")
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "A_STOP_OK=0 reason=invalid_pid"; exit 1; }
process_stopped() {
  if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  state=$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}')
  [[ "$state" = Z* ]]
}
if process_stopped; then rm -f "$A_PID_FILE"; echo "A_STOP_OK=1 already_stopped=1 pid=$pid state=${state:-gone}"; exit 0; fi
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
[ -n "$pgid" ] || { echo "A_STOP_OK=0 reason=missing_pgid"; exit 1; }
kill -TERM -- "-$pgid"
for _ in $(seq 1 40); do
  if process_stopped; then rm -f "$A_PID_FILE"; echo "A_STOP_OK=1 pid=$pid pgid=$pgid signal=TERM state=${state:-gone}"; exit 0; fi
  sleep 0.1
done
kill -KILL -- "-$pgid" 2>/dev/null || true
for _ in $(seq 1 20); do
  if process_stopped; then rm -f "$A_PID_FILE"; echo "A_STOP_OK=1 pid=$pid pgid=$pgid signal=KILL state=${state:-gone}"; exit 0; fi
  sleep 0.1
done
echo "A_STOP_OK=0 reason=still_running pid=$pid pgid=$pgid"; exit 1
