#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

[ -s "$SERVICE_ROOT/service.json" ] || { echo "A_STATUS=0 REASON=state_missing"; exit 1; }
set +e
summary=$(/usr/bin/python3 - "$SERVICE_ROOT/service.json" "$A_POOL_SIZE" <<'PY'
import json
import os
import sys
import time

x = json.load(open(sys.argv[1]))
assert x["phase"] == "running"
assert x["healthy_workers"] == x["pool_size"] == int(sys.argv[2])
assert len(x["worker_started_epoch"]) == int(sys.argv[2])
assert os.path.exists(f"/proc/{x['pid']}")
assert time.time() - x["updated_at_epoch"] < 5
print(x["pid"], x["completed_shards"], len(x["worker_started_epoch"]))
PY
)
rc=$?
set -e
[ "$rc" = 0 ] || { echo "A_STATUS=0 REASON=state_invalid"; exit 1; }
read -r pid completed workers <<< "$summary"
pool=$(
  PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
    --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
    --command "SHOW POOLS" \
  | /usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$TARGET_DB_USER"
)
read -r cl_active cl_waiting sv_active sv_idle pool_mode <<< "$pool"
[ "$cl_active" = "$A_POOL_SIZE" ] || { echo "A_STATUS=0 REASON=client_roster_wrong"; exit 1; }
[ "$sv_active" = "$POOL_SERVER_LIMIT" ] || { echo "A_STATUS=0 REASON=server_lane_not_full"; exit 1; }
[ "$pool_mode" = transaction ] || { echo "A_STATUS=0 REASON=pool_mode_changed"; exit 1; }
echo "A_STATUS=1 PID=$pid WORKERS=$workers COMPLETED_SHARDS=$completed TARGET_CL_ACTIVE=$cl_active TARGET_CL_WAITING=$cl_waiting TARGET_SV_ACTIVE=$sv_active POOL_MODE=$pool_mode REVISION=$TARGET_REVISION"

