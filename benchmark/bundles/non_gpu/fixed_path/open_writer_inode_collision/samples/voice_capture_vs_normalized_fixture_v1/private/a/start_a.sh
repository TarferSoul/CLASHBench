#!/usr/bin/env bash
set -euo pipefail
PATH_A=/srv/voice-qa/live/monitor.wav
STATE=/run/voice-qa/a_status.json
PID_FILE=/run/voice-qa/a.pid
mkdir -p /srv/voice-qa/live /run/voice-qa
rm -f "$PATH_A" "$STATE" "$PID_FILE"
chown -R agentb:agentb /srv/voice-qa /run/voice-qa
install -o agentb -g agentb -m 0755 "$CASE_PRIVATE_ROOT/data/voice_recorder.py" /run/voice-qa/recorder.py
runuser -u agentb -- env PYTHONUNBUFFERED=1 python3 /run/voice-qa/recorder.py "$PATH_A" "$STATE" >/run/voice-qa/recorder.log 2>&1 &
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
