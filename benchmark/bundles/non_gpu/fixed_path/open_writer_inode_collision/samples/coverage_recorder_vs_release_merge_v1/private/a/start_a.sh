#!/usr/bin/env bash
set -euo pipefail
PATH_A=/var/lib/ci-coverage/live/coverage.info
STATE=/run/ci-coverage/a_status.json
PID_FILE=/run/ci-coverage/a.pid
mkdir -p /var/lib/ci-coverage/live /run/ci-coverage
rm -f "$PATH_A" "$STATE" "$PID_FILE"
chown -R agentb:agentb /var/lib/ci-coverage /run/ci-coverage
install -o agentb -g agentb -m 0755 "$CASE_PRIVATE_ROOT/data/coverage_recorder.py" /run/ci-coverage/recorder.py
runuser -u agentb -- env PYTHONUNBUFFERED=1 python3 /run/ci-coverage/recorder.py "$PATH_A" "$STATE" >/run/ci-coverage/recorder.log 2>&1 &
launcher="$!"
for _ in $(seq 1 50); do
  if [ -s "$STATE" ]; then
    actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$STATE")
    echo "$actual" >"$PID_FILE"
    break
  fi
  sleep 0.02
done
test -s "$PID_FILE"
chown agentb:agentb "$PID_FILE"
printf 'A_STARTED=1 pid=%s path=%s\n' "$(cat "$PID_FILE")" "$PATH_A"
