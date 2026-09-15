#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"

mkdir -p "$A_HELPER_ROOT"
chmod 0755 "$A_HELPER_ROOT"
install -m 0555 "$ROOT/data/ci_retention_worker.py" "$A_HELPER_PATH"
rm -f "$A_PID_FILE" "$A_LOG_FILE"
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups \
  python3 "$A_HELPER_PATH" run-a --project "$PROJECT_ROOT" \
    --retention "$A_RETENTION_ROOT" --runtime "$A_RUNTIME_ROOT" \
    --retained-bytes "$A_RETAINED_BYTES" >"$A_LOG_FILE" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
chmod 0600 "$A_PID_FILE" "$A_LOG_FILE"
echo "A_STARTED=1 PID=$pid"
