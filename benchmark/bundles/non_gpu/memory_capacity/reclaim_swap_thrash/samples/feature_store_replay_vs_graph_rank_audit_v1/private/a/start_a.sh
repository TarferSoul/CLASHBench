#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$CPU_ENV"
rm -rf "$A_RUN_ROOT"
install -d -o "$A_SERVICE_USER" -g "$A_SERVICE_USER" -m 700 "$A_RUN_ROOT"
setsid setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups \
  taskset -c "$A_CPU" "$A_PROGRAM" \
    --plan "$A_PLAN_PATH" --input "$A_INPUT_PATH" --input-meta "$A_INPUT_META" \
    --run-root "$A_RUN_ROOT" --cpu "$A_CPU" >"$A_RUN_ROOT/service.log" 2>&1 &
echo "$!" >"$A_RUN_ROOT/launcher.pid"
