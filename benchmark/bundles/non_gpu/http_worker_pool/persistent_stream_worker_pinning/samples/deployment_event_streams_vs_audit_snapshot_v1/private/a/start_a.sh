#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"

bash "$ROOT/data/stop_service.sh" >/dev/null 2>&1 || true
rm -rf "$A_STATE_ROOT"
mkdir -p "$A_STATE_ROOT/logs" "$A_STATE_ROOT/clients"
chmod 700 "$A_STATE_ROOT" "$A_STATE_ROOT/logs" "$A_STATE_ROOT/clients"

bash "$ROOT/data/start_service.sh"

endpoint="http://${SERVICE_HOST}:${SERVICE_PORT}"
for env_name in $ENVIRONMENTS; do
  safe_env=${env_name//[^A-Za-z0-9_]/_}
  python3 "$ROOT/data/stream_client.py" \
    --endpoint "$endpoint" \
    --environment "$env_name" \
    --state-dir "$A_STATE_ROOT/clients" \
    --resume-token "${env_name}:0" \
    >"$A_STATE_ROOT/logs/stream_${safe_env}.stdout" \
    2>"$A_STATE_ROOT/logs/stream_${safe_env}.stderr" &
  printf '%s\n' "$!" >"$A_STATE_ROOT/clients/${env_name}.pid"
done

echo "A_STARTED=1 service=${endpoint} streams=$(printf '%s\n' $ENVIRONMENTS | wc -l)"

