#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$A_PID_DIR" "$A_PROGRESS_DIR" "$LICENSE_ROOT/logs"
rm -f "$A_PID_DIR"/*.pid "$A_PRIMARY_PID_FILE" "$A_PROGRESS_DIR"/*.json
for role in eda-synthesis-stage eda-timing-stage; do
  runuser -u agentb -- env LICENSE_SOCKET="$LICENSE_SOCKET" LICENSE_CONFIG="$LICENSE_CONFIG" \
    python3 "$RUNTIME_WORKER" --socket "$LICENSE_SOCKET" --config "$LICENSE_CONFIG" --role "$role" --progress "$A_PROGRESS_DIR/$role.json" \
    >"$LICENSE_ROOT/logs/$role.log" 2>&1 &
  launcher_pid=$!; printf '%s\n' "$launcher_pid" > "$A_PID_DIR/$role.launcher.pid"
  actual_pid=
  for _ in $(seq 1 80); do
    if [ -s "$A_PROGRESS_DIR/$role.json" ]; then actual_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_PROGRESS_DIR/$role.json"); break; fi
    sleep 0.05
  done
  case "$actual_pid" in ''|*[!0-9]*) echo "A_START_FAIL=WORKER_PID_MISSING role=$role" >&2; exit 1 ;; esac
  printf '%s\n' "$actual_pid" > "$A_PID_DIR/$role.pid"
  [ -e "$A_PRIMARY_PID_FILE" ] || printf '%s\n' "$actual_pid" > "$A_PRIMARY_PID_FILE"
done
printf 'A_STARTED=1 roles=2\n'
