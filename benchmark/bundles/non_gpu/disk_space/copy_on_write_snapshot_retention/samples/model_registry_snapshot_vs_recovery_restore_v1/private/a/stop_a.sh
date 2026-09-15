#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
mode=${1:-force}
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
snapshot_uuid=$(python3 - "$A_SNAPSHOT_FILE" 2>/dev/null <<'PY' || true
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["uuid"])
PY
)
if [ "$mode" = normal ] && [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  runuser -u "$AGENT_USER" -- touch "$A_COMPLETE_REQUEST"
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo 'A_STOP_FAIL=normal_completion_timeout'
    exit 3
  fi
  python3 - "$A_RECEIPT_FILE" "$snapshot_uuid" <<'PY'
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert receipt["completed"] is True
assert receipt["released_snapshot_uuid"] == sys.argv[2]
PY
  printf 'A_COMPLETED=1 pid=%s released_snapshot_uuid=%s\n' "$pid" "$snapshot_uuid"
  exit 0
fi
if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  runuser -u "$AGENT_USER" -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$pid" 2>/dev/null && runuser -u "$AGENT_USER" -- kill -KILL "$pid" 2>/dev/null || true
fi
printf 'A_STOPPED=1 mode=force pid=%s snapshot_uuid=%s\n' "${pid:-none}" "${snapshot_uuid:-none}"
