#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

rm -f "$SERVICE_ROOT/service.json" "$SERVICE_ROOT/service.log" "$SERVICE_ROOT/service.pid"
setsid setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
  /usr/bin/python3 "$SERVICE_APP" --config "$SERVICE_CONFIG" \
  > "$SERVICE_ROOT/service.log" 2>&1 &
launch_pid=$!
printf '%s\n' "$launch_pid" > "$SERVICE_ROOT/service.pid"
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_ROOT/service.pid"

ready=0
for _ in $(seq 1 320); do
  if [ -s "$SERVICE_ROOT/service.json" ]; then
    set +e
    summary=$(/usr/bin/python3 - "$SERVICE_ROOT/service.json" "$A_POOL_SIZE" "$A_READY_MIN_CHECKPOINTS" <<'PY'
import json
import os
import sys
import time

x = json.load(open(sys.argv[1]))
assert x["phase"] == "running"
assert x["healthy_workers"] == x["pool_size"] == int(sys.argv[2])
assert x["completed_checkpoint_count"] >= int(sys.argv[3])
assert len(x["worker_started_epoch"]) == int(sys.argv[2])
assert os.path.exists(f"/proc/{x['pid']}")
assert time.time() - x["updated_at_epoch"] < 5
print(x["pid"], x["completed_checkpoint_count"], len(x["worker_started_epoch"]), x["rows_hashed"])
PY
    )
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      read -r service_pid checkpoints workers rows_hashed <<< "$summary"
      set +e
      pool=$(
        PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
          --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
          --command "SHOW POOLS" \
        | /usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$TARGET_DB_USER"
      )
      pool_rc=$?
      set -e
      if [ "$pool_rc" = 0 ]; then
        read -r cl_active cl_waiting sv_active sv_idle pool_mode <<< "$pool"
        if [ "$cl_active" = "$A_POOL_SIZE" ] \
            && [ "$sv_active" = "$POOL_SERVER_LIMIT" ] \
            && [ "$pool_mode" = transaction ]; then
          ready=1
          break
        fi
      fi
    fi
  fi
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  tail -100 "$SERVICE_ROOT/service.log" >&2 || true
  tail -100 "$POOL_LOG" >&2 || true
  echo "A_START_FAILED feature_parity_validator_not_ready" >&2
  exit 1
fi
echo "A_READY=1 PID=$service_pid WORKERS=$workers CHECKPOINTS=$checkpoints ROWS_HASHED=$rows_hashed TARGET_CL_ACTIVE=$cl_active TARGET_SV_ACTIVE=$sv_active POOL_MODE=$pool_mode MODEL_VERSION=$MODEL_VERSION GENERATION=$SERVICE_GENERATION"
