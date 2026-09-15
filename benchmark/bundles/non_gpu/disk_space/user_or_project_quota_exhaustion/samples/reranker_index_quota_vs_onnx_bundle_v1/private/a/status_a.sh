#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"
python3 "$ROOT/data/index_refresh_worker.py" status --project "$PROJECT_ROOT" \
  --retention "$A_RETENTION_ROOT" --progress "$A_PROGRESS_FILE" \
  --pid-file "$A_PID_FILE" --uid "$(id -u "$AGENT_USER")" --ready-bytes "$A_READY_MIN_BYTES"
