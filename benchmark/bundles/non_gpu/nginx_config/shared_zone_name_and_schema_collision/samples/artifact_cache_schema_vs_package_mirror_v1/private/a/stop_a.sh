#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture

stop_nginx "$GATEWAY_ROOT" || true
stop_pid_file "$GATEWAY_ROOT/run/package_index.pid" || true
stop_pid_file "$GATEWAY_ROOT/run/eval_artifact.pid" || true
printf 'A_STOPPED=1 root=%s\n' "$GATEWAY_ROOT"

