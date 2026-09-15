#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    printf 'A_ALREADY_RUNNING=1 pid=%s\n' "$old_pid"
    exit 0
  fi
fi
rm -rf "$VOLUME_ROOT"
rm -f "$A_PID_FILE" "$A_LAUNCHER_PID_FILE" "$A_SNAPSHOT_FILE" "$A_PROGRESS_FILE" \
  "$A_RECEIPT_FILE" "$A_COMPLETE_REQUEST" "$A_LOG_FILE"
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" format \
  --volume "$VOLUME_ROOT" --capacity "$VOLUME_CAPACITY" --extent-size "$EXTENT_SIZE" \
  --label "$VOLUME_LABEL" >"$A_RUNTIME_ROOT/format.json"
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" apply \
  --volume "$VOLUME_ROOT" --spec "$A_SEED_SPEC" >"$A_RUNTIME_ROOT/seed_apply.json"
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" snapshot-create \
  --volume "$VOLUME_ROOT" --name edge-golden-pre-rebase-export >"$A_SNAPSHOT_FILE"
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" apply \
  --volume "$VOLUME_ROOT" --spec "$A_CURRENT_SPEC" >"$A_RUNTIME_ROOT/current_apply.json"
snapshot_uuid=$(python3 - "$A_SNAPSHOT_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["uuid"])
PY
)
: >"$A_LOG_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_LOG_FILE" "$A_SNAPSHOT_FILE"
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/image_export_worker.py" \
  --cowfs "$A_RUNTIME_ROOT/cowfs.py" --volume "$VOLUME_ROOT" --snapshot "$snapshot_uuid" \
  --snapshot-spec "$A_SEED_SPEC" --current-spec "$A_CURRENT_SPEC" \
  --pid-file "$A_PID_FILE" --progress "$A_PROGRESS_FILE" \
  --complete-request "$A_COMPLETE_REQUEST" --receipt "$A_RECEIPT_FILE" \
  >>"$A_LOG_FILE" 2>&1 &
printf '%s\n' "$!" >"$A_LAUNCHER_PID_FILE"
pid=
for _ in $(seq 1 100); do
  pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  if [[ $pid =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then break; fi
  sleep 0.05
done
case "$pid" in *[!0-9]*|'') echo 'A_START_FAIL=pid_missing'; exit 3 ;; esac
printf 'A_STARTED=1 pid=%s snapshot_uuid=%s volume=%s\n' "$pid" "$snapshot_uuid" "$VOLUME_ROOT"
