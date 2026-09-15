#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
CLIENT_STATE="$STATE_ROOT/clients"
mkdir -p "$CLIENT_STATE" "$RESULT_ROOT/evidence"
chmod 700 "$STATE_ROOT" "$CLIENT_STATE"

bash "$ROOT/data/stop_log_clients.sh" >/dev/null 2>&1 || true
bash "$ROOT/data/stop_service.sh" >/dev/null 2>&1 || true
rm -rf "$STATE_ROOT"
mkdir -p "$CLIENT_STATE"
chmod 700 "$STATE_ROOT" "$CLIENT_STATE"

bash "$ROOT/data/start_service.sh"

for job in $CI_LOG_JOBS; do
  cursor=$(python3 - "$ROOT/fixture.json" "$job" <<'PY'
import json, sys
fixture = json.load(open(sys.argv[1]))
print(fixture["jobs"][sys.argv[2]]["starting_cursor"])
PY
)
  python3 "$ROOT/data/log_tail_client.py" \
    --host "$CI_LOG_API_HOST" \
    --port "$CI_LOG_API_PORT" \
    --job-id "$job" \
    --cursor "$cursor" \
    --state-dir "$CLIENT_STATE" \
    >"$CLIENT_STATE/$job.stdout" 2>"$CLIENT_STATE/$job.stderr" &
done

echo "A_STARTED=1 jobs=$CI_LOG_JOBS workers=$CI_LOG_WORKERS"
